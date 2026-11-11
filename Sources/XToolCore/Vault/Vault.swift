import Foundation

public enum VaultError: Error, LocalizedError {
    case alreadyExists
    case locked
    case indexCorrupted
    case invalidBackup
    case newerFormat
    case notEnoughSpace(needed: Int64, available: Int64)
    case busy
    case renewalUnfinished(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists: return "A vault already exists."
        case .locked: return "The vault is locked."
        case .indexCorrupted: return "The vault index is damaged and could not be read."
        case .invalidBackup: return "This is not a valid xTool backup."
        case .newerFormat: return "This vault was made by a newer version of xTool."
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "Not enough free space: \(f(needed, .file)) needed, \(f(available, .file)) available."
        case .busy: return "The vault is being re-encrypted. Please wait until it has finished."
        case .renewalUnfinished(let detail):
            return "The new key is in place, but tidying up did not finish (\(detail)). Quit and reopen xTool to complete it."
        }
    }
}

/// The encrypted vault on disk (format: docs/FORMAT.md):
///   vault.json  – Argon2id parameters + wrapped master key
///   index.bin   – encrypted index (folders, file names, notes, boards, settings), index.bak = previous version
///   blobs/xx/id – encrypted file contents
public final class Vault {
    public static let formatVersion = 1
    private static let keyAad = Data("xtool-master-key-v1".utf8)
    private static let indexAad = Data("xtool-index-v1".utf8)

    public let root: URL
    public private(set) var header: VaultHeader
    private let keyLock = NSLock()
    private var masterKey: SecretKey?
    /// Counts master keys: an index sealed under an older key is never written.
    private var keyEpoch = 0
    /// While a new master key is being made, nothing else may read or write content.
    private var renewing = false
    private let writeQueue = DispatchQueue(label: "xtool.vault.write")

    public var index = VaultIndex()
    /// True if index.bin was damaged and the previous copy (index.bak) had to be used.
    public private(set) var loadedFromIndexBackup = false

    public var isUnlocked: Bool {
        keyLock.lock(); defer { keyLock.unlock() }
        return masterKey != nil
    }

    public var headerURL: URL { root.appendingPathComponent("vault.json") }
    public var indexURL: URL { root.appendingPathComponent("index.bin") }
    public var indexBackupURL: URL { root.appendingPathComponent("index.bak") }
    public var blobsURL: URL { root.appendingPathComponent("blobs", isDirectory: true) }

    private init(root: URL, header: VaultHeader) {
        self.root = root
        self.header = header
    }

    /// ~/Library/Application Support/xTool/Vault (inside the app sandbox container).
    public static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["XTOOL_VAULT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("xTool/Vault", isDirectory: true)
    }

    public static func exists(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("vault.json").path)
    }

    // MARK: lifecycle

    public static func create(at root: URL, password: String, params: KdfParams = .default) throws -> Vault {
        if exists(at: root) { throw VaultError.alreadyExists }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        var newKey = Aead.randomBytes(Aead.keySize)
        defer { newKey.resetBytes(in: 0..<newKey.count) }
        let header = try wrap(masterKey: newKey, password: password, params: params)
        let vault = Vault(root: root, header: header)
        vault.masterKey = SecretKey(copying: newKey)
        try vault.writeDurably(try XJSON.encoder().encode(header), to: vault.headerURL)
        vault.index.boards.append(.makeDefault("My tasks"))
        try vault.saveIndex()
        return vault
    }

    public static func open(at root: URL) throws -> Vault {
        try finishInterruptedRenewal(root: root)
        let data = try Data(contentsOf: root.appendingPathComponent("vault.json"))
        let header = try XJSON.decoder().decode(VaultHeader.self, from: data)
        guard header.version <= formatVersion else { throw VaultError.newerFormat }
        return Vault(root: root, header: header)
    }

    /// Slow by design (Argon2id). Returns false on a wrong password.
    public func unlock(password: String) throws -> Bool {
        guard var key = try Vault.unwrap(header: header, password: password) else { return false }
        setKey(SecretKey(copying: key))
        key.resetBytes(in: 0..<key.count)
        do {
            index = try loadIndex()
        } catch {
            lock()
            throw error
        }
        removeLeftoverTempFiles()
        return true
    }

    public static func checkPassword(header: VaultHeader, password: String) throws -> Bool {
        try unwrap(header: header, password: password) != nil
    }

    public func lock() {
        keyLock.lock()
        masterKey = nil // wiped as soon as a job still using it has finished
        keyLock.unlock()
        index = VaultIndex()
    }

    public func changePassword(old: String, new: String) throws -> Bool {
        guard var key = try Vault.unwrap(header: header, password: old) else { return false }
        defer { key.resetBytes(in: 0..<key.count) }
        var newHeader = try Vault.wrap(masterKey: key, password: new, params: .default)
        newHeader.created = header.created
        try writeQueue.sync { try writeDurably(try XJSON.encoder().encode(newHeader), to: headerURL) }
        header = newHeader
        return true
    }

    /// A vault from an older version gets today's protection against password guessing. Only vault.json changes,
    /// written atomically, and only if the new protection is stronger. Older backups stay as they are.
    @discardableResult
    public func upgradeKeyProtectionIfNeeded(password: String) -> Bool {
        guard isUnlocked, header.memoryKiB < KdfParams.default.memoryKiB,
              let key = try? key(), let upgraded = try? Vault.wrap(masterKey: key, password: password, params: .default) else { return false }
        var newHeader = upgraded
        newHeader.created = header.created
        do {
            try writeQueue.sync { try writeDurably(try XJSON.encoder().encode(newHeader), to: headerURL) }
            header = newHeader
            return true
        } catch {
            return false
        }
    }

    // MARK: index

    private func loadIndex() throws -> VaultIndex {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) || fm.fileExists(atPath: indexBackupURL.path) else { return VaultIndex() }
        for url in [indexURL, indexBackupURL] where fm.fileExists(atPath: url.path) {
            if let sealed = try? Data(contentsOf: url),
               var plain = try? Aead.open(key: try key(), sealed: sealed, aad: Vault.indexAad) {
                defer { plain.resetBytes(in: 0..<plain.count) }
                guard let idx = try? XJSON.decoder().decode(VaultIndex.self, from: plain) else { continue }
                guard idx.version <= Vault.formatVersion else { throw VaultError.newerFormat }
                loadedFromIndexBackup = url == indexBackupURL
                return idx
            }
        }
        throw VaultError.indexCorrupted
    }

    /// Serializes on the calling thread, encrypts and writes atomically.
    public func saveIndex() throws {
        let sealed = try sealIndex()
        let retired = takeRetired()
        try writeQueue.sync {
            do { try writeIndexFile(sealed) } catch { giveBackRetired(retired); throw error }
            finishRetired(retired)
        }
    }

    /// Fire-and-forget variant used by the UI (debounced). Writes keep their order.
    public func saveIndexInBackground(completion: @escaping (Error?) -> Void) {
        do {
            let sealed = try sealIndex()
            let retired = takeRetired()
            writeQueue.async {
                do {
                    try self.writeIndexFile(sealed)
                    self.finishRetired(retired)
                    completion(nil)
                } catch {
                    self.giveBackRetired(retired)
                    completion(error)
                }
            }
        } catch {
            completion(error)
        }
    }

    public func waitForWrites() { writeQueue.sync {} }

    private struct SealedIndex { let data: Data; let epoch: Int }

    private func sealIndex() throws -> SealedIndex {
        let (key, epoch) = try keyAndEpoch()
        return SealedIndex(data: try sealIndex(index, key: key), epoch: epoch)
    }

    private func sealIndex(_ index: VaultIndex, key: Data) throws -> Data {
        var json = try XJSON.encoder().encode(index)
        defer { json.resetBytes(in: 0..<json.count) }
        return try Aead.seal(key: key, plaintext: json, aad: Vault.indexAad)
    }

    private func writeIndexFile(_ sealed: SealedIndex) throws {
        keyLock.lock()
        let current = keyEpoch, busy = renewing
        keyLock.unlock()
        guard sealed.epoch == current, !busy else { throw VaultError.busy }
        let fm = FileManager.default
        if fm.fileExists(atPath: indexURL.path) {
            try? fm.removeItem(at: indexBackupURL)
            try? fm.copyItem(at: indexURL, to: indexBackupURL)
        }
        try writeDurably(sealed.data, to: indexURL)
    }

    /// Temp file, flushed to the physical disk, then an atomic rename(2): a crash leaves the old or the new file, never half.
    private func writeDurably(_ data: Data, to url: URL) throws {
        try Vault.writeDurably(data, to: url)
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
        if rename(tmp.path, url.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    // MARK: retired blobs

    // A blob that left the index is wiped only once an index without it is on disk,
    // so a failed or interrupted save can never leave the index pointing at content that is gone.

    private let retiredLock = NSLock()
    private var retired: [String] = []
    private var deletionHolds = 0
    private var heldDeletions: [String] = []

    public func retireBlob(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        retiredLock.lock(); retired.append(id); retiredLock.unlock()
    }

    private func takeRetired() -> [String] {
        retiredLock.lock(); defer { retiredLock.unlock() }
        let r = retired
        retired = []
        return r
    }

    private func giveBackRetired(_ ids: [String]) {
        retiredLock.lock(); retired.insert(contentsOf: ids, at: 0); retiredLock.unlock()
    }

    private func finishRetired(_ ids: [String]) {
        retiredLock.lock()
        if deletionHolds > 0 {
            heldDeletions.append(contentsOf: ids)
            retiredLock.unlock()
            return
        }
        retiredLock.unlock()
        ids.forEach(deleteBlob)
    }

    /// While `body` runs (a backup), no blob disappears: what the copied index references stays complete.
    func holdingDeletions<T>(_ body: () throws -> T) rethrows -> T {
        retiredLock.lock(); deletionHolds += 1; retiredLock.unlock()
        defer {
            retiredLock.lock()
            deletionHolds -= 1
            let ids = deletionHolds == 0 ? heldDeletions : []
            if deletionHolds == 0 { heldDeletions = [] }
            retiredLock.unlock()
            ids.forEach(deleteBlob)
        }
        return try body()
    }

    // MARK: blobs

    private func blobURL(_ id: String) -> URL { Vault.blobURL(id, in: blobsURL) }

    private static func blobURL(_ id: String, in folder: URL) -> URL {
        folder.appendingPathComponent(String(id.prefix(2)), isDirectory: true).appendingPathComponent(id)
    }

    /// Writes a new blob through a temp file; it appears under its final name only when complete and on disk.
    private func createBlob(_ body: (_ handle: FileHandle, _ id: String) throws -> Void) throws -> String {
        let id = Ids.new()
        let url = blobURL(id)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try body(handle, id)
            try handle.synchronize()
            try handle.close()
            try fm.moveItem(at: tmp, to: url)
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
        return id
    }

    /// Encrypts small content held in memory. Thread-safe (does not touch the index).
    public func writeBlob(_ data: Data) throws -> String {
        let key = try key()
        return try createBlob { handle, id in
            try handle.write(contentsOf: try BlobCipher.encrypt(data, masterKey: key, blobId: id))
        }
    }

    /// Encrypts a file of any size, one chunk at a time. Thread-safe. Throw from `progress` to cancel.
    public func importBlob(from url: URL, progress: BlobCipher.Progress? = nil) throws -> (id: String, size: Int64) {
        let key = try key()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var size: Int64 = 0
        let id = try createBlob { output, id in
            size = try BlobCipher.encrypt(
                read: { try input.read(upToCount: $0) ?? Data() },
                write: { try output.write(contentsOf: $0) },
                masterKey: key, blobId: id, progress: progress)
        }
        return (id, size)
    }

    /// Decrypts a blob of any size to `destination`. The file appears under its final name only when complete
    /// and fully authenticated; on any failure no plaintext stays behind. Thread-safe.
    public func exportBlob(_ id: String, to destination: URL, progress: BlobCipher.Progress? = nil) throws {
        let key = try key()
        let input = try FileHandle(forReadingFrom: blobURL(id))
        defer { try? input.close() }
        let fm = FileManager.default
        let tmp = destination.appendingPathExtension("xtoolpart")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        let output = try FileHandle(forWritingTo: tmp)
        do {
            try BlobCipher.decrypt(
                read: { try input.read(upToCount: $0) ?? Data() },
                write: { try output.write(contentsOf: $0) },
                masterKey: key, blobId: id, progress: progress)
            try output.synchronize()
            try output.close()
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            try? output.close()
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Copies a blob under fresh keys without loading it. Thread-safe.
    public func copyBlob(_ id: String, progress: BlobCipher.Progress? = nil) throws -> (id: String, size: Int64) {
        let key = try key()
        let input = try FileHandle(forReadingFrom: blobURL(id))
        defer { try? input.close() }
        var size: Int64 = 0
        let newId = try createBlob { output, newId in
            size = try BlobCipher.reencrypt(
                read: { try input.read(upToCount: $0) ?? Data() },
                write: { try output.write(contentsOf: $0) },
                masterKey: key, fromBlobId: id, toBlobId: newId, progress: progress)
        }
        return (newId, size)
    }

    public func readBlob(_ id: String) throws -> Data {
        try BlobCipher.decrypt(try Data(contentsOf: blobURL(id)), masterKey: try key(), blobId: id)
    }

    /// First chunk of a blob and whether that is the whole file.
    public func readBlobStart(_ id: String) throws -> (data: Data, isWholeFile: Bool) {
        let key = try key()
        let input = try FileHandle(forReadingFrom: blobURL(id))
        defer { try? input.close() }
        return try BlobCipher.firstChunk(read: { try input.read(upToCount: $0) ?? Data() }, masterKey: key, blobId: id)
    }

    public func blobPlaintextSize(_ id: String) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: blobURL(id))
        defer { try? input.close() }
        return try BlobCipher.plaintextSize(of: input)
    }

    public func blobExists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: blobURL(id).path) }

    public func blobModificationDate(_ id: String) -> Date? {
        try? blobURL(id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Ids of all blob files on disk.
    public func allBlobIds() -> [String] {
        guard let e = FileManager.default.enumerator(at: blobsURL, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.count == 32 && !$0.contains(".") }
    }

    /// Overwrites with random bytes, then deletes.
    public func deleteBlob(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        Vault.overwriteAndDelete(blobURL(id))
    }

    /// Temp files of an interrupted write. They hold only encrypted data and are never referenced.
    private func removeLeftoverTempFiles() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: blobsURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.pathExtension == "tmp" { try? fm.removeItem(at: url) }
    }

    // MARK: new master key

    // Changing the password only re-wraps the master key. Renewing replaces the key itself: every blob and the index
    // are encrypted again under a new random key, so an old vault.json or backup together with an old password
    // opens nothing that exists from now on.
    //
    // Crash safety: everything new is written to rekey/ first, the live vault stays untouched. The single commit point
    // is the atomic rename of rekey/vault.json over vault.json. Before it, rekey/ is thrown away on the next start;
    // after it, the next start completes the move (finishInterruptedRenewal). The format of the vault does not change.

    static let renewalFolder = "rekey"
    /// Tests: behave like a crash right after the commit point.
    nonisolated(unsafe) static var stopAfterCommitForTesting = false
    private static let keepList = "keep.txt"

    /// Ids of every blob the index refers to, in the trash and in versions too.
    public func referencedBlobIds() -> [String] {
        var ids: [String] = []
        for node in index.nodes {
            ids += [node.blobId, node.thumbBlobId].compactMap { $0 }
            ids += (node.versions ?? []).map(\.blobId)
        }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Bytes the renewal needs on disk: one more copy of everything the index refers to.
    public func renewalSize() -> Int64 {
        referencedBlobIds().reduce(Int64(0)) { sum, id in
            sum + Int64((try? blobURL(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Encrypts everything again under a new random master key, protected by `newPassword` (or the current one).
    /// Returns false if `password` is wrong. `progress` reports bytes done and may throw to cancel, until the commit.
    /// Nothing else may use the vault meanwhile; reads and writes fail with `VaultError.busy`.
    public func renewMasterKey(password: String, newPassword: String? = nil, params: KdfParams = .default,
                               progress: ((_ done: Int64, _ total: Int64) throws -> Void)? = nil) throws -> Bool {
        guard try Vault.unwrap(header: header, password: password) != nil else { return false }
        let oldKey = try key()
        let snapshot = index
        let ids = referencedBlobIds().filter(blobExists)
        let total = renewalSize()
        try DiskSpace.ensure(total, at: root)

        writeQueue.sync {} // index writes already queued go out under the old key first
        keyLock.lock(); renewing = true; keyLock.unlock()
        var committed = false
        defer {
            keyLock.lock(); renewing = false; keyLock.unlock()
            if !committed { try? FileManager.default.removeItem(at: root.appendingPathComponent(Vault.renewalFolder)) }
        }

        let fm = FileManager.default
        let staging = root.appendingPathComponent(Vault.renewalFolder, isDirectory: true)
        try? fm.removeItem(at: staging)
        let stagedBlobs = staging.appendingPathComponent("blobs", isDirectory: true)
        try fm.createDirectory(at: stagedBlobs, withIntermediateDirectories: true)

        var newKey = Aead.randomBytes(Aead.keySize)
        defer { newKey.resetBytes(in: 0..<newKey.count) }

        var done: Int64 = 0
        try progress?(0, total)
        for id in ids {
            let target = Vault.blobURL(id, in: stagedBlobs)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = target.appendingPathExtension("tmp")
            guard fm.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: blobURL(id))
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: tmp)
            do {
                let base = done
                _ = try BlobCipher.reencrypt(
                    read: { try input.read(upToCount: $0) ?? Data() },
                    write: { try output.write(contentsOf: $0) },
                    masterKey: oldKey, fromBlobId: id, toBlobId: id, newMasterKey: newKey,
                    progress: { bytes in try progress?(base + bytes, total) })
                try output.synchronize()
                _ = fcntl(output.fileDescriptor, F_FULLFSYNC)
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            guard rename(tmp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            done += Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try progress?(done, total)
        }

        try Vault.writeDurably(Data(ids.joined(separator: "\n").utf8), to: staging.appendingPathComponent(Vault.keepList))
        try Vault.writeDurably(try sealIndex(snapshot, key: newKey), to: staging.appendingPathComponent("index.bin"))
        var newHeader = try Vault.wrap(masterKey: newKey, password: newPassword ?? password, params: params)
        newHeader.created = header.created
        try Vault.writeDurably(try XJSON.encoder().encode(newHeader), to: staging.appendingPathComponent("vault.json"))

        // the commit point
        guard rename(staging.appendingPathComponent("vault.json").path, headerURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        committed = true
        if Vault.stopAfterCommitForTesting { return true }
        keyLock.lock()
        if masterKey != nil { masterKey = SecretKey(copying: newKey) } // locked meanwhile: stays locked
        keyEpoch += 1
        keyLock.unlock()
        header = newHeader
        do {
            try Vault.finishInterruptedRenewal(root: root)
        } catch {
            throw VaultError.renewalUnfinished(error.localizedDescription)
        }
        return true
    }

    /// Completes or discards a renewal that a crash interrupted. Needs no key: it only moves and deletes files.
    static func finishInterruptedRenewal(root: URL) throws {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(renewalFolder, isDirectory: true)
        guard fm.fileExists(atPath: staging.path) else { return }
        // not committed: the live vault is complete and untouched
        if fm.fileExists(atPath: staging.appendingPathComponent("vault.json").path) {
            try fm.removeItem(at: staging)
            return
        }
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        // Written before the commit. If it can't be read, stop: guessing would delete content.
        let keep = Set(try String(contentsOf: staging.appendingPathComponent(keepList), encoding: .utf8)
            .split(separator: "\n").map(String.init))

        let stagedIndex = staging.appendingPathComponent("index.bin")
        if fm.fileExists(atPath: stagedIndex.path) {
            try writeDurably(try Data(contentsOf: stagedIndex), to: root.appendingPathComponent("index.bak"))
            guard rename(stagedIndex.path, root.appendingPathComponent("index.bin").path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let stagedBlobs = staging.appendingPathComponent("blobs", isDirectory: true)
        if let e = fm.enumerator(at: stagedBlobs, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension.isEmpty && keep.contains(url.lastPathComponent) {
                let target = blobURL(url.lastPathComponent, in: blobs)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard rename(url.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        // Anything else was encrypted under the old key and is referenced by nothing.
        if let e = fm.enumerator(at: blobs, includingPropertiesForKeys: nil) {
            for case let url as URL in e where !keep.contains(url.lastPathComponent) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { overwriteAndDelete(url) }
            }
        }
        try fm.removeItem(at: staging)
    }

    private static func overwriteAndDelete(_ url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: 0)
            var remaining = Int64(size)
            while remaining > 0 {
                let n = Int(min(remaining, 1 << 20))
                autoreleasepool { try? handle.write(contentsOf: Aead.randomBytes(n)) }
                remaining -= Int64(n)
            }
            try? handle.synchronize()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: helpers

    private func key() throws -> Data {
        try keyAndEpoch().0
    }

    private func keyAndEpoch() throws -> (Data, Int) {
        keyLock.lock(); defer { keyLock.unlock() }
        guard let k = masterKey else { throw VaultError.locked }
        guard !renewing else { throw VaultError.busy }
        return (k.data, keyEpoch)
    }

    private func setKey(_ key: SecretKey) {
        keyLock.lock(); masterKey = key; keyLock.unlock()
    }

    private static func wrap(masterKey: Data, password: String, params: KdfParams) throws -> VaultHeader {
        let salt = Aead.randomBytes(KdfParams.saltSize)
        var kek = try KeyDerivation.deriveKey(password: password, salt: salt, params: params)
        defer { kek.resetBytes(in: 0..<kek.count) }
        let wrapped = try Aead.seal(key: kek, plaintext: masterKey, aad: keyAad)
        return VaultHeader(params: params, salt: salt, wrappedKey: wrapped)
    }

    private static func unwrap(header: VaultHeader, password: String) throws -> Data? {
        guard let salt = Data(base64Encoded: header.salt), let wrapped = Data(base64Encoded: header.wrappedKey) else {
            throw VaultError.indexCorrupted
        }
        var kek = try KeyDerivation.deriveKey(password: password, salt: salt, params: header.params)
        defer { kek.resetBytes(in: 0..<kek.count) }
        return try? Aead.open(key: kek, sealed: wrapped, aad: keyAad)
    }
}

public enum DiskSpace {
    /// Space macOS can make available on the volume of `url` (includes purgeable data).
    public static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Throws if `bytes` plus a small reserve won't fit.
    public static func ensure(_ bytes: Int64, at url: URL) throws {
        guard let free = available(at: url) else { return }
        let needed = bytes + 64 * 1024 * 1024
        if free < needed { throw VaultError.notEnoughSpace(needed: needed, available: free) }
    }
}
