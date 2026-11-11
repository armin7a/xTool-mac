import Foundation
@testable import XToolCore

/// A new master key: everything readable afterwards, nothing readable with the old key file, safe against crashes.
struct RenewalTests {
    private let fast = KdfParams(memoryKiB: 8 * 1024, iterations: 1, parallelism: 1)

    private struct Setup {
        let root: URL
        let vault: Vault
        let contents: [String: Data]   // node id → content
    }

    private func makeVault() throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-renew-\(UUID().uuidString)/Vault")
        let vault = try Vault.create(at: root, password: "old password", params: fast)
        let drive = Drive(vault: vault)
        let folder = drive.createFolder(in: nil, name: "Sources")
        var contents: [String: Data] = [:]
        let big = Data((0..<(3 * BlobCipher.defaultChunkSize + 123)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let a = try drive.addFile(in: folder.id, name: "interview.txt", content: Data("first draft".utf8))
        try drive.updateContent(a.id, Data("second draft".utf8))   // keeps a version
        contents[a.id] = Data("second draft".utf8)
        let b = try drive.addFile(in: nil, name: "recording.bin", content: big)
        contents[b.id] = big
        let c = try drive.addFile(in: nil, name: "empty.txt", content: Data())
        contents[c.id] = Data()
        let d = try drive.addFile(in: nil, name: "old.txt", content: Data("in the trash".utf8))
        drive.trash([d.id])
        contents[d.id] = Data("in the trash".utf8)
        var note = Note()
        note.title = "Contact"
        note.text = "meet at the station"
        vault.index.notes.append(note)
        try vault.saveIndex()
        return Setup(root: root, vault: vault, contents: contents)
    }

    private func check(_ s: Setup, password: String) throws {
        let vault = try Vault.open(at: s.root)
        expect(try vault.unlock(password: password), "unlocks with \(password)")
        let drive = Drive(vault: vault)
        for (id, data) in s.contents {
            let node = try require(drive.get(id))
            expect(try drive.readContent(node) == data, "content of \(node.name)")
            for v in node.versions ?? [] { expect((try? drive.readVersion(v)) != nil, "version of \(node.name)") }
        }
        expect(vault.index.notes.first?.text == "meet at the station")
        let onDisk = Set(vault.allBlobIds()), referenced = Set(vault.referencedBlobIds())
        expect(onDisk == referenced, "no stray blobs: \(onDisk.subtracting(referenced).count) extra, \(referenced.subtracting(onDisk).count) missing")
        expect(!FileManager.default.fileExists(atPath: s.root.appendingPathComponent("rekey").path), "staging removed")
    }

    func everythingStaysReadableAndTheOldKeyFileOpensNothing() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        let oldHeader = try Data(contentsOf: s.vault.headerURL)
        let anyBlob = try require(s.vault.referencedBlobIds().first)
        let oldBlob = try Data(contentsOf: s.vault.blobsURL.appendingPathComponent(String(anyBlob.prefix(2))).appendingPathComponent(anyBlob))

        var reports = 0
        expect(try s.vault.renewMasterKey(password: "old password", params: fast) { _, _ in reports += 1 })
        expect(reports > 0, "progress reported")
        // the running vault keeps working with the new key
        expect(try s.vault.readBlob(anyBlob).count >= 0)
        try s.vault.saveIndex()
        try check(s, password: "old password")
        let newBlob = try Data(contentsOf: s.vault.blobsURL.appendingPathComponent(String(anyBlob.prefix(2))).appendingPathComponent(anyBlob))
        expect(newBlob != oldBlob, "blob encrypted again")

        // An attacker with the OLD vault.json and the old password: the key it unlocks opens nothing any more.
        try oldHeader.write(to: s.vault.headerURL)
        let stale = try Vault.open(at: s.root)
        expectThrows { try stale.unlock(password: "old password") }
    }

    func newPasswordReplacesTheOldOne() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        expect(try s.vault.renewMasterKey(password: "old password", newPassword: "new password", params: fast))
        expect(try !Vault.open(at: s.root).unlock(password: "old password"))
        try check(s, password: "new password")
    }

    func wrongPasswordChangesNothing() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        let before = try Data(contentsOf: s.vault.headerURL)
        expect(try !s.vault.renewMasterKey(password: "wrong", params: fast))
        expect(try Data(contentsOf: s.vault.headerURL) == before)
        try check(s, password: "old password")
    }

    func cancellingLeavesTheVaultAsItWas() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        let before = try Data(contentsOf: s.vault.headerURL)
        struct Stop: Error {}
        var calls = 0
        expectThrows {
            try s.vault.renewMasterKey(password: "old password", params: fast) { done, _ in
                calls += 1
                if done > 0 { throw Stop() }
            }
        }
        expect(try Data(contentsOf: s.vault.headerURL) == before)
        // still usable, saving works again
        try s.vault.saveIndex()
        try check(s, password: "old password")
    }

    func crashBeforeTheSwitchIsDiscarded() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        // what a crash leaves: a full staging folder whose vault.json was never moved
        let staging = s.root.appendingPathComponent("rekey")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("blobs/ab"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: staging.appendingPathComponent("blobs/ab/abababababababababababababababab"))
        try Data("{}".utf8).write(to: staging.appendingPathComponent("vault.json"))
        try Data("x".utf8).write(to: staging.appendingPathComponent("keep.txt"))
        try check(s, password: "old password")
    }

    func crashAfterTheSwitchIsCompletedOnNextStart() throws {
        let s = try makeVault()
        defer { try? FileManager.default.removeItem(at: s.root.deletingLastPathComponent()) }
        Vault.stopAfterCommitForTesting = true
        defer { Vault.stopAfterCommitForTesting = false }
        expect(try s.vault.renewMasterKey(password: "old password", newPassword: "new password", params: fast))
        Vault.stopAfterCommitForTesting = false
        expect(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("rekey/index.bin").path), "crash left the move unfinished")
        try check(s, password: "new password")   // open() finishes the move
    }
}
