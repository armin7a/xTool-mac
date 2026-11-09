import Foundation
import ZIPFoundation

/// .xvault = zip of the encrypted vault files, opened with the password that was set at backup time.
public enum Backup {
    /// What a restore found.
    public struct RestoreResult {
        /// Files in the backup's index whose content is missing from the backup.
        public let missingFiles: Int
        /// Where the replaced vault was kept.
        public let previousVault: URL?
    }

    public static func create(vault: Vault, to destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        // An existing file is only replaced once the new one is complete. A new file is written in place:
        // the sandbox allows writing to exactly the chosen path, and an external disk may be the only one with room.
        let replacing = fm.fileExists(atPath: destination.path)
        let target = replacing
            ? vault.root.deletingLastPathComponent().appendingPathComponent("backup-\(UUID().uuidString).tmp")
            : destination
        do {
            try vault.holdingDeletions {
                let archive = try Archive(url: target, accessMode: .create, pathEncoding: nil)
                // Index first, then the blob list: every blob the copied index references is on the list,
                // and none can vanish while deletions are held.
                var files = [vault.headerURL, vault.indexURL]
                if fm.fileExists(atPath: vault.indexBackupURL.path) { files.append(vault.indexBackupURL) }
                for file in files { try add(file, vault: vault, to: archive) }

                let blobs = blobFiles(in: vault)
                let total = max(1, blobs.reduce(Int64(0)) { $0 + $1.size })
                var done: Int64 = 0
                for blob in blobs {
                    try autoreleasepool { try add(blob.url, vault: vault, to: archive) }
                    done += blob.size
                    progress?(Double(done) / Double(total))
                }
            }
            if replacing {
                try fm.removeItem(at: destination)
                try fm.moveItem(at: target, to: destination)
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    private static func add(_ file: URL, vault: Vault, to archive: Archive) throws {
        let root = vault.root.standardizedFileURL.path
        var rel = String(file.standardizedFileURL.path.dropFirst(root.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        // encrypted data does not compress – store it
        try archive.addEntry(with: rel, fileURL: file, compressionMethod: .none, bufferSize: 1 << 20)
    }

    private static func blobFiles(in vault: Vault) -> [(url: URL, size: Int64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: vault.blobsURL, includingPropertiesForKeys: Array(keys)) else { return [] }
        var result: [(URL, Int64)] = []
        for case let url as URL in e where url.pathExtension != "tmp" {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            result.append((url, Int64(v.fileSize ?? 0)))
        }
        return result
    }

    public static func checkPassword(backup: URL, password: String) throws -> Bool {
        try Vault.checkPassword(header: try readHeader(backup: backup), password: password)
    }

    private static func readHeader(backup: URL) throws -> VaultHeader {
        let archive = try Archive(url: backup, accessMode: .read, pathEncoding: nil)
        guard let entry = archive["vault.json"] else { throw VaultError.invalidBackup }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try XJSON.decoder().decode(VaultHeader.self, from: data)
    }

    /// Replaces the vault folder – but only after the backup was unpacked and proved readable with `password`.
    /// The previous vault stays next to it as "Vault.vor-Wiederherstellung <date>".
    @discardableResult
    public static func restore(backup: URL, to vaultRoot: URL, password: String, progress: ((Double) -> Void)? = nil) throws -> RestoreResult {
        let fm = FileManager.default
        let parent = vaultRoot.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("Vault.restore-tmp", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let backupSize = (try? backup.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        try DiskSpace.ensure(backupSize, at: parent)

        let archive = try Archive(url: backup, accessMode: .read, pathEncoding: nil)
        let root = staging.standardizedFileURL.path + "/"
        var done: Int64 = 0
        for entry in archive where entry.type == .file {
            let target = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path.hasPrefix(root) else { continue } // zip-slip guard
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try autoreleasepool { _ = try archive.extract(entry, to: target, bufferSize: 1 << 20, skipCRC32: true) }
            done += Int64(entry.uncompressedSize)
            progress?(Double(done) / Double(max(backupSize, 1)))
        }
        guard Vault.exists(at: staging) else { throw VaultError.invalidBackup }

        // proves the password and that the index is intact, before anything is replaced
        let check = try Vault.open(at: staging)
        guard try check.unlock(password: password) else { throw XToolCryptoError.wrongKey }
        let missing = check.index.nodes.filter { node in
            node.deletedAt == nil && node.blobId.map { !check.blobExists($0) } ?? false
        }.count
        check.lock()

        var previous: URL?
        if fm.fileExists(atPath: vaultRoot.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateTimeSeparator(.space))
            let url = parent.appendingPathComponent("Vault.vor-Wiederherstellung \(stamp)", isDirectory: true)
            try fm.moveItem(at: vaultRoot, to: url)
            previous = url
        }
        try fm.moveItem(at: staging, to: vaultRoot)
        return RestoreResult(missingFiles: missing, previousVault: previous)
    }
}
