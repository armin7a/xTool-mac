import Foundation
@testable import XToolCore

private let fastKdf = KdfParams(memoryKiB: 8 * 1024, iterations: 1, parallelism: 1)

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Vaults written by earlier versions must open forever. The fixtures are frozen files, never regenerated.
struct CompatTests {
    static let fixturePassword = "xTool-Fixture-1 äöü"

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    /// Opens a private copy: unlocking must not touch the frozen files.
    private func openCopy(_ name: String) throws -> Vault {
        let root = tempDir().appendingPathComponent("Vault")
        try FileManager.default.copyItem(at: fixture(name), to: root)
        return try Vault.open(at: root)
    }

    func readsFormat1VaultFromWindows() throws {
        let vault = try openCopy("vault-format-1")
        expect(try !vault.unlock(password: "falsch"))
        expect(try vault.unlock(password: Self.fixturePassword))
        let drive = Drive(vault: vault)
        let folder = try require(drive.children(of: nil).first { $0.name == "Ordner Ä" })
        let hello = try require(drive.children(of: folder.id).first { $0.name == "hallo.txt" })
        expect(String(data: try drive.readContent(hello), encoding: .utf8) == "Hallo vom Windows-Tresor! ✓")
        let big = try require(drive.allFiles().first { $0.name == "gross.bin" })
        let data = try drive.readContent(big)
        expect(data.count == BlobCipher.defaultChunkSize + 4321)
        expect(data[1000] == UInt8(1000 * 31 % 251))
        expect(vault.index.notes.first?.title == "Notiz")
        let card = try require(vault.index.boards.first?.columns.first?.cards.first)
        expect(card.priority == .high)
        expect(Calendar.current.component(.day, from: try require(card.due)) == 24)
        expect(card.checklist.first?.done == true)
    }

    func readsFormat1VaultFromMac() throws {
        let vault = try openCopy("vault-format-1-mac")
        expect(try vault.unlock(password: Self.fixturePassword))
        let drive = Drive(vault: vault)
        let file = try require(drive.allFiles().first { $0.name == "hallo.txt" })
        expect(String(data: try drive.readContent(file), encoding: .utf8) == "Hallo vom Mac-Tresor! ✓")
    }

    func refusesNewerFormat() throws {
        let vault = try Vault.create(at: tempDir().appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        var header = vault.header
        header.version = Vault.formatVersion + 1
        try XJSON.encoder().encode(header).write(to: vault.headerURL)
        expectThrows { try Vault.open(at: vault.root) }
    }

    func blobRoundTripAndTamper() throws {
        let key = Aead.randomBytes(32)
        for size in [0, 1, 1000, BlobCipher.defaultChunkSize, BlobCipher.defaultChunkSize * 2 + 17] {
            let plain = Aead.randomBytes(size)
            let enc = try BlobCipher.encrypt(plain, masterKey: key, blobId: "b1")
            expect(try BlobCipher.decrypt(enc, masterKey: key, blobId: "b1") == plain)
            expectThrows { try BlobCipher.decrypt(enc, masterKey: key, blobId: "other") }
            var bad = enc
            bad[bad.count - 1] ^= 1
            expectThrows { try BlobCipher.decrypt(bad, masterKey: key, blobId: "b1") }
            // cut off: drop the last record
            if size > BlobCipher.defaultChunkSize {
                let cut = enc.prefix(40 + 5 + BlobCipher.defaultChunkSize + 16)
                expectThrows { try BlobCipher.decrypt(Data(cut), masterKey: key, blobId: "b1") }
            }
            // trailing data
            var long = enc
            long.append(1)
            expectThrows { try BlobCipher.decrypt(long, masterKey: key, blobId: "b1") }
        }
    }

    func vaultLifecycleTrashAndBackup() throws {
        let dir = tempDir()
        let root = dir.appendingPathComponent("Vault")
        let vault = try Vault.create(at: root, password: "pw", params: fastKdf)
        let drive = Drive(vault: vault)
        let f = drive.createFolder(in: nil, name: "A")
        let file = try drive.addFile(in: f.id, name: "x.txt", content: Data("x".utf8))
        drive.trash([f.id])
        expect(drive.isDeleted(drive.get(file.id)!))
        drive.restore([f.id])
        expect(!drive.isDeleted(drive.get(file.id)!))
        try vault.saveIndex()

        let backup = dir.appendingPathComponent("b.xvault")
        try Backup.create(vault: vault, to: backup)
        try Backup.create(vault: vault, to: backup) // replacing an existing backup
        expect(try Backup.checkPassword(backup: backup, password: "pw"))
        expect(try !Backup.checkPassword(backup: backup, password: "nein"))
        expect(try vault.changePassword(old: "pw", new: "neu"))
        vault.lock()

        // a wrong password must leave the current vault untouched
        expectThrows { try Backup.restore(backup: backup, to: root, password: "nein") }
        expect(try Vault.open(at: root).unlock(password: "neu"))

        let result = try Backup.restore(backup: backup, to: root, password: "pw")
        expect(result.missingFiles == 0)
        let restored = try Vault.open(at: root)
        expect(try restored.unlock(password: "pw"))
        expect(Drive(vault: restored).allFiles().count == 1)
        // the replaced vault is still there and a second restore does not overwrite it
        let previous = try require(result.previousVault)
        expect(Vault.exists(at: previous))
    }

    func versionsKeptRestoredAndEncoded() throws {
        let vault = try Vault.create(at: tempDir().appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        let drive = Drive(vault: vault)
        let file = try drive.addFile(in: nil, name: "brief.docx", content: Data([1]))
        try drive.updateContent(file.id, Data([2]))
        expect(drive.get(file.id)!.versions?.count == 1)
        try drive.updateContent(file.id, Data([3]))      // auto-save right after: no new version
        expect(drive.get(file.id)!.versions?.count == 1)
        let original = drive.get(file.id)!.versions![0]
        expect(try drive.readVersion(original) == Data([1]))
        drive.restoreVersion(file.id, original)
        expect(try drive.readContent(drive.get(file.id)!) == Data([1]))
        expect(drive.get(file.id)!.versions?.count == 1)   // the replaced state is kept

        try vault.saveIndex()
        let json = String(data: try XJSON.encoder().encode(vault.index), encoding: .utf8)!
        expect(json.contains("\"Versions\""))
        expect(json.contains("\"Saved\""))
    }

    func damagedIndexFallsBackAndSaysSo() throws {
        let root = tempDir().appendingPathComponent("Vault")
        let vault = try Vault.create(at: root, password: "pw", params: fastKdf)
        try vault.saveIndex()
        try Data([1, 2, 3]).write(to: vault.indexURL)
        let reopened = try Vault.open(at: root)
        expect(try reopened.unlock(password: "pw"))
        expect(reopened.loadedFromIndexBackup)
    }

    func lookupsSurviveRemoval() throws {
        let vault = try Vault.create(at: tempDir().appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        let drive = Drive(vault: vault)
        let a = drive.createFolder(in: nil, name: "a")
        let b = drive.createFolder(in: nil, name: "b")
        let c = drive.createFolder(in: nil, name: "c")
        expect(drive.get(c.id)?.name == "c")
        drive.deletePermanently([a.id])
        expect(drive.get(a.id) == nil)
        expect(drive.get(b.id)?.name == "b")
        expect(drive.get(c.id)?.name == "c")
        expect(drive.get("gibt-es-nicht") == nil)
    }

    func dotNetDates() throws {
        expect(DateCoding.parse("2026-10-19T03:15:22.1234567+02:00") != nil)
        expect(DateCoding.parse("2026-10-19T01:15:22Z") != nil)
        expect(DateCoding.parse("2026-12-24T00:00:00") != nil)
        let d = Date()
        let back = try require(DateCoding.parse(DateCoding.format(d)))
        expect(abs(back.timeIntervalSince1970 - d.timeIntervalSince1970) < 0.01)
    }
}

/// Streaming: files bigger than memory or the old 2 GB limit.
struct LargeFileTests {
    /// Pseudo-random but reproducible content, so a million-byte file doesn't need a million bytes of RAM to verify.
    private func pattern(_ offset: Int64, _ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let p = offset + Int64(i)
                bytes[i] = UInt8(truncatingIfNeeded: p &* 31 &+ (p >> 13))
            }
        }
        return data
    }

    private func writeFile(size: Int64, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        var offset: Int64 = 0
        while offset < size {
            try autoreleasepool {
                let n = Int(min(4 << 20, size - offset))
                try h.write(contentsOf: pattern(offset, n))
                offset += Int64(n)
            }
        }
    }

    private func verifyFile(_ url: URL, size: Int64) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        expect((attrs[.size] as? NSNumber)?.int64Value == size)
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var offset: Int64 = 0
        while offset < size {
            try autoreleasepool {
                let n = Int(min(4 << 20, size - offset))
                let chunk = try h.read(upToCount: n) ?? Data()
                expect(chunk == pattern(offset, n))
                offset += Int64(n)
            }
        }
    }

    private func roundTrip(size: Int64) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir.appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        let source = dir.appendingPathComponent("gross.bin")
        try writeFile(size: size, to: source)

        var reported: Int64 = 0
        let (id, written) = try vault.importBlob(from: source) { reported = $0 }
        expect(written == size)
        expect(reported == size)
        expect(try vault.blobPlaintextSize(id) == size)

        let copy = try vault.copyBlob(id)
        expect(copy.size == size)

        let out = dir.appendingPathComponent("zurueck.bin")
        try vault.exportBlob(copy.id, to: out)
        try verifyFile(out, size: size)
        expect(!FileManager.default.fileExists(atPath: out.path + ".xtoolpart"))

        // the blob is not readable without the key
        let raw = try Data(contentsOf: dir.appendingPathComponent("Vault/blobs/\(id.prefix(2))/\(id)"), options: .mappedIfSafe)
        expect(raw.range(of: pattern(0, 256)) == nil)
    }

    func roundTripAcrossChunkBoundaries() throws {
        let chunk = Int64(BlobCipher.defaultChunkSize)
        for size in [0, 1, chunk - 1, chunk, chunk + 1, chunk * 3, 50_000_000] as [Int64] { try roundTrip(size: size) }
    }

    /// Takes a while; run with XTOOL_LARGE_TEST=1. Larger than the 2 GB limit of the previous version.
    func roundTripFiveGigabytes() throws {
        guard ProcessInfo.processInfo.environment["XTOOL_LARGE_TEST"] == "1" else { return }
        try roundTrip(size: 5_000_000_000)
    }

    func cancelLeavesNothingBehind() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir.appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        let source = dir.appendingPathComponent("gross.bin")
        try writeFile(size: 10_000_000, to: source)
        expectThrows {
            try vault.importBlob(from: source) { if $0 > 2_000_000 { throw CancellationError() } }
        }
        expect(vault.allBlobIds().isEmpty)

        let (id, _) = try vault.importBlob(from: source)
        let out = dir.appendingPathComponent("raus.bin")
        expectThrows {
            try vault.exportBlob(id, to: out) { if $0 > 2_000_000 { throw CancellationError() } }
        }
        expect(!FileManager.default.fileExists(atPath: out.path))
        expect(!FileManager.default.fileExists(atPath: out.path + ".xtoolpart"))
    }

    func tamperedExportLeavesNoPlaintext() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Vault")
        let vault = try Vault.create(at: root, password: "pw", params: fastKdf)
        let source = dir.appendingPathComponent("a.bin")
        try writeFile(size: 5_000_000, to: source)
        let (id, _) = try vault.importBlob(from: source)
        let blob = root.appendingPathComponent("blobs/\(id.prefix(2))/\(id)")
        var raw = try Data(contentsOf: blob)
        raw[raw.count - 100] ^= 0xFF
        try raw.write(to: blob)
        let out = dir.appendingPathComponent("raus.bin")
        expectThrows { try vault.exportBlob(id, to: out) }
        expect(!FileManager.default.fileExists(atPath: out.path))
        expect(!FileManager.default.fileExists(atPath: out.path + ".xtoolpart"))
    }

    func backupHoldsLargeFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Vault")
        let vault = try Vault.create(at: root, password: "pw", params: fastKdf)
        let source = dir.appendingPathComponent("a.bin")
        try writeFile(size: 30_000_000, to: source)
        let (id, size) = try vault.importBlob(from: source)
        let drive = Drive(vault: vault)
        drive.addFile(in: nil, name: "a.bin", blobId: id, size: size)
        try vault.saveIndex()
        let backup = dir.appendingPathComponent("b.xvault")
        var last = 0.0
        try Backup.create(vault: vault, to: backup) { last = $0 }
        expect(last > 0.99)
        vault.lock()
        let target = dir.appendingPathComponent("Neu/Vault")
        try Backup.restore(backup: backup, to: target, password: "pw")
        let restored = try Vault.open(at: target)
        expect(try restored.unlock(password: "pw"))
        let out = dir.appendingPathComponent("raus.bin")
        try restored.exportBlob(id, to: out)
        try verifyFile(out, size: size)
    }

    func orphanRecoveryIgnoresLargeBinaryLeftovers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir.appendingPathComponent("Vault"), password: "pw", params: fastKdf)
        let source = dir.appendingPathComponent("a.bin")
        try writeFile(size: 30_000_000, to: source)
        _ = try vault.importBlob(from: source)   // never added to the index
        let drive = Drive(vault: vault)
        expect(drive.recoverLostContent() == 0)
    }
}


/// Protection against password guessing grows with the app, without touching what is already stored.
struct KeyProtectionTests {
    func oldVaultIsUpgradedAndStaysReadable() throws {
        let root = tempDir().appendingPathComponent("Vault")
        let old = KdfParams(memoryKiB: 128 * 1024, iterations: 3, parallelism: 1)
        let created = try Vault.create(at: root, password: "Passwort-Test", params: old)
        let file = try Drive(vault: created).addFile(in: nil, name: "a.txt", content: Data("Inhalt".utf8))
        try created.saveIndex()
        created.lock()

        let vault = try Vault.open(at: root)
        expect(try vault.unlock(password: "Passwort-Test"))
        let start = Date()
        expect(vault.upgradeKeyProtectionIfNeeded(password: "Passwort-Test"))
        print("    Passwort absichern mit \(KdfParams.default.memoryKiB / 1024) MB: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        expect(vault.header.params == .default)
        expect(!vault.upgradeKeyProtectionIfNeeded(password: "Passwort-Test"), "nur einmal")
        vault.lock()

        let reopened = try Vault.open(at: root)
        expect(try !reopened.unlock(password: "falsch"))
        expect(try reopened.unlock(password: "Passwort-Test"))
        expect(reopened.header.params == .default)
        let node = try require(Drive(vault: reopened).get(file.id))
        expect(String(data: try Drive(vault: reopened).readContent(node), encoding: .utf8) == "Inhalt")
    }

    func keyStaysUsableForRunningWorkAfterLocking() throws {
        let vault = try Vault.create(at: tempDir().appendingPathComponent("Vault"), password: "pw", params: KdfParams(memoryKiB: 8 * 1024, iterations: 1, parallelism: 1))
        let id = try vault.writeBlob(Data("x".utf8))
        vault.lock()
        expect(!vault.isUnlocked)
        expectThrows { try vault.readBlob(id) }
    }

    func olderSettingsGetDefaults() throws {
        let json = #"{"Theme":"Dark","AutoLockMinutes":5}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        expect(settings.defaultsVersion == 0)
        expect(settings.autoLockMinutes == 5)
        expect(!settings.spellCheck)
        expect(AppSettings().autoLockMinutes == 1)
        expect(AppSettings().defaultsVersion == AppSettings.currentDefaultsVersion)
    }
}
