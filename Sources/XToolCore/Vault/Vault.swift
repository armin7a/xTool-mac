import Foundation

public enum VaultError: Error, LocalizedError {
    case alreadyExists
    case locked
    case indexCorrupted
    case invalidBackup
    case newerFormat
    case notEnoughSpace(needed: Int64, available: Int64)

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

    private func sealIndex() throws -> Data {
        var json = try XJSON.encoder().encode(index)
        defer { json.resetBytes(in: 0..<json.count) }
        return try Aead.seal(key: try key(), plaintext: json, aad: Vault.indexAad)
    }

    private func writeIndexFile(_ sealed: Data) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: indexURL.path) {
            try? fm.removeItem(at: indexBackupURL)
            try? fm.copyItem(at: indexURL, to: indexBackupURL)
        }
        try writeDurably(sealed, to: indexURL)
    }

    /// Temp file, flushed to the physical disk, then an atomic rename(2): a crash leaves the old or the new file, never half.
    private func writeDurably(_ data: Data, to url: URL) throws {
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

    private func blobURL(_ id: String) -> URL {
        blobsURL.appendingPathComponent(String(id.prefix(2)), isDirectory: true).appendingPathComponent(id)
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
        let url = blobURL(id)
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

    /// Temp files of an interrupted write. They hold only encrypted data and are never referenced.
    private func removeLeftoverTempFiles() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: blobsURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.pathExtension == "tmp" { try? fm.removeItem(at: url) }
    }

    // MARK: helpers

    private func key() throws -> Data {
        keyLock.lock(); defer { keyLock.unlock() }
        guard let k = masterKey else { throw VaultError.locked }
        return k.data
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
