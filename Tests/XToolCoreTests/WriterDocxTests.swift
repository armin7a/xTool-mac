import AppKit
import ZIPFoundation
@testable import XToolCore

/// "Saved a document, can't open it again" (macOS): the .docx written by the Writer must be readable by the
/// macOS text system again – with header, footer and page numbers, and after several saves.
struct WriterDocxTests {
    private func makeDocx(_ text: String) throws -> Data {
        let s = NSMutableAttributedString(string: "Rechnung\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        return try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML, .author: "xTool",
        ])
    }

    private func reopen(_ data: Data) throws -> (String, String?) {
        var attrs: NSDictionary?
        let s = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: &attrs)
        return (s.string, attrs?[NSAttributedString.DocumentAttributeKey.author] as? String)
    }

    func savedDocumentOpensAgain() throws {
        let raw = try makeDocx("Sehr geehrte Frau Beispiel, äöü ß €.")
        var page = PageSetup()
        page.header = "Max Mustermann · vertraulich & <privat>"
        page.footer = "Erstellt mit xTool"
        page.pageNumbers = true
        page.landscape = true

        let saved = DocxPage.apply(raw, page)
        expect(saved != raw)
        let (text, author) = try reopen(saved)
        expect(text.contains("Sehr geehrte Frau Beispiel, äöü ß €."))
        expect(author == "xTool")

        let back = DocxPage.read(saved)
        expect(back.header == page.header)
        expect(back.footer == page.footer)
        expect(back.pageNumbers)
        expect(back.landscape)

        // patching an already patched file (save → open → save) must not stack parts or break it
        let twice = DocxPage.apply(saved, page)
        _ = try reopen(twice)
        expect(DocxPage.read(twice).header == page.header)

        // without header/footer
        _ = try reopen(DocxPage.apply(raw, PageSetup()))
    }

    private func tempVault() throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-tests-\(UUID().uuidString)")
        return try Vault.create(at: dir.appendingPathComponent("Vault"), password: "pw", params: KdfParams(memoryKiB: 8 * 1024, iterations: 1, parallelism: 1))
    }

    /// The bug behind "saved, then can't open it": the replaced content was wiped before the index was written.
    func replacedContentStaysUntilIndexIsSaved() throws {
        let vault = try tempVault()
        let drive = Drive(vault: vault)
        let file = try drive.addFile(in: nil, name: "a.txt", content: Data("1".utf8))
        try drive.updateContent(file.id, Data("2".utf8))   // original → version
        try vault.saveIndex()
        let replaced = drive.get(file.id)!.blobId!
        try drive.updateContent(file.id, Data("3".utf8))   // right after: "2" is replaced
        expect(vault.blobExists(replaced))
        try vault.saveIndex()
        expect(!(vault.blobExists(replaced)))
        // index written via rename – reopening works
        vault.lock()
        expect(try vault.unlock(password: "pw"))
        expect(try Drive(vault: vault).readContent(Drive(vault: vault).get(file.id)!) == Data("3".utf8))
    }

    /// Vaults already damaged by 1.1/1.2: the newer content still exists as an unreferenced blob.
    func lostDocumentsAreRecovered() throws {
        let vault = try tempVault()
        let drive = Drive(vault: vault)
        let doc = try drive.addFile(in: nil, name: "Brief.docx", content: try makeDocx("alt"))
        try vault.saveIndex()
        // what 1.1/1.2 left behind: new content written, old one wiped, index never updated
        let newer = try vault.writeBlob(try makeDocx("NEU gespeichert"))
        vault.deleteBlob(doc.blobId)
        expectThrows { try drive.readContent(drive.get(doc.id)!) }

        expect(drive.recoverLostContent() == 1)
        expect(drive.get(doc.id)!.blobId == newer)
        expect(try reopen(drive.readContent(drive.get(doc.id)!)).0.contains("NEU gespeichert"))

        // a new document whose first save never reached the index
        let lostNew = try vault.writeBlob(try makeDocx("ganz neues Dokument"))
        expect(drive.recoverLostContent() == 1)
        let folder = drive.children(of: nil).first { $0.isFolder && $0.name == "Recovered" }
        expect(folder != nil)
        expect(drive.children(of: folder!.id).first?.blobId == lostNew)
        expect(drive.recoverLostContent() == 0)
    }

    /// Files saved by xTool 1.1/1.2 were patched in place; they must open after repairing.
    func oldPatchedFilesCanBeRepaired() throws {
        let raw = try makeDocx("Alter Stand")
        let legacy = try legacyApply(raw)
        let legacyOpens = (try? reopen(legacy)) != nil
        print("legacy in-place patched docx opens on macOS: \(legacyOpens)")
        let repaired = DocxPage.repaired(legacy, withoutExtras: false)
        let stripped = DocxPage.repaired(legacy, withoutExtras: true)
        expect(stripped != nil)
        let ok = [legacy, repaired, stripped].compactMap { $0 }.contains { (try? reopen($0))?.0.contains("Alter Stand") == true }
        expect(ok)
    }

    /// The old in-place patch (ZIPFoundation update mode on an in-memory archive), as shipped in 1.1/1.2.
    private func legacyApply(_ data: Data) throws -> Data {
        let archive = try Archive(data: data, accessMode: .update, pathEncoding: nil)
        func read(_ path: String) throws -> String {
            var d = Data()
            _ = try archive.extract(archive[path]!) { d.append($0) }
            return String(data: d, encoding: .utf8)!
        }
        func write(_ path: String, _ text: String) throws {
            if let e = archive[path] { try archive.remove(e) }
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { pos, size in
                bytes.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        var rels = try read("word/_rels/document.xml.rels")
        var types = try read("[Content_Types].xml")
        let doc = try read("word/document.xml")
        try write("word/footer_xtool.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>x</w:t></w:r></w:p></w:ftr>"#)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: #"<Relationship Id="rIdXtoolFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer_xtool.xml"/></Relationships>"#)
        types = types.replacingOccurrences(of: "</Types>", with: #"<Override PartName="/word/footer_xtool.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>"#)
        try write("word/document.xml", doc)
        try write("word/_rels/document.xml.rels", rels)
        try write("[Content_Types].xml", types)
        return archive.data!
    }
}
