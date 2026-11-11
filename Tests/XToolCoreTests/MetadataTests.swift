import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import XToolCore

/// Exported copies must not tell who made a file, with what, or where.
struct MetadataTests {
    /// Words that only appear in the planted metadata.
    static let secrets = ["Jane Reporter", "secret comment", "MakerCo", "ModelZ", "Zurich", "LensXYZ", "2026:01:02", "XmpSource"]

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func leaks(_ url: URL) -> [String] {
        let bytes = (try? Data(contentsOf: url)) ?? Data()
        return Self.secrets.filter { bytes.range(of: Data($0.utf8)) != nil }
    }

    private func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        return ctx.makeImage()!
    }

    private func writeTaggedImage(_ url: URL, type: UTType) throws {
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret comment", kCGImagePropertyExifLensModel: "LensXYZ",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "MakerCo", kCGImagePropertyTIFFModel: "ModelZ",
                                             kCGImagePropertyTIFFArtist: "Jane Reporter"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Jane Reporter"], kCGImagePropertyIPTCCity: "Zurich"],
        ]
        let dst = try require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, picture(), props as CFDictionary)
        expect(CGImageDestinationFinalize(dst))
    }

    func photosLoseLocationCameraAndNames() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (ext, type) in [("jpg", UTType.jpeg), ("png", .png), ("heic", .heic), ("tiff", .tiff)] {
            let url = dir.appendingPathComponent("photo.\(ext)")
            try writeTaggedImage(url, type: type)
            expect(!MetadataScrubber.remainingMetadata(at: url).isEmpty, "\(ext): the test image must carry metadata")
            expect(try MetadataScrubber.scrub(url) == .cleaned, ext)
            expect(MetadataScrubber.remainingMetadata(at: url).isEmpty, "\(ext): \(MetadataScrubber.remainingMetadata(at: url))")
            expect(leaks(url).isEmpty, "\(ext) leaks \(leaks(url))")
            let src = try require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            expect(props[kCGImagePropertyOrientation] as? Int == 6, "\(ext): orientation must survive")
            expect(props[kCGImagePropertyPixelWidth] as? Int == 64, "\(ext): picture must survive")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("xtoolclean") }
        expect(left.isEmpty, "temporary files left: \(left)")
    }

    func pdfLosesAuthorAndHiddenXMP() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("report.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let info: [CFString: Any] = [kCGPDFContextAuthor: "Jane Reporter", kCGPDFContextCreator: "MakerCo", kCGPDFContextTitle: "ModelZ",
                                     kCGPDFContextKeywords: "Zurich"]
        let ctx = try require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        ctx.addDocumentMetadata(Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:CreatorTool>XmpSource</xmp:CreatorTool></rdf:Description></rdf:RDF></x:xmpmeta>"#.utf8) as CFData)
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        // the second page is shown turned, as scanners often do it
        let doc = try require(PDFDocument(url: url))
        doc.page(at: 1)?.rotation = 90
        expect(doc.write(to: url))
        expect(!MetadataScrubber.remainingMetadata(at: url).isEmpty, "the test PDF must carry metadata")

        expect(try MetadataScrubber.scrub(url) == .cleaned)
        expect(MetadataScrubber.remainingMetadata(at: url).isEmpty, "\(MetadataScrubber.remainingMetadata(at: url))")
        expect(leaks(url).isEmpty, "leaks \(leaks(url))")
        let clean = try require(PDFDocument(url: url))
        expect(clean.pageCount == 2)
        expect(clean.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 200))
        expect(clean.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 200, height: 300), "turned page keeps its look")
    }

    func protectedPdfIsLeftAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("locked.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = try require(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextUserPassword: "pw", kCGPDFContextOwnerPassword: "pw"] as CFDictionary))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let before = try Data(contentsOf: url)
        expectThrows { try MetadataScrubber.scrub(url) }
        expect(try Data(contentsOf: url) == before, "a file that cannot be cleaned stays as it was")
    }

    func officeLosesAuthorsAndEditors() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("story.docx")
        let entries: [DocxPage.Entry] = [
            ("[Content_Types].xml", Data(#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#.utf8)),
            ("docProps/core.xml", Data(#"<?xml version="1.0"?><cp:coreProperties xmlns:cp="c" xmlns:dc="d"><dc:creator>Jane Reporter</dc:creator><cp:lastModifiedBy>Jane Reporter</cp:lastModifiedBy></cp:coreProperties>"#.utf8)),
            ("docProps/app.xml", Data(#"<?xml version="1.0"?><Properties xmlns="p"><Company>MakerCo</Company><Manager>ModelZ</Manager></Properties>"#.utf8)),
            ("word/document.xml", Data(#"<?xml version="1.0"?><w:document xmlns:w="w"><w:body><w:p><w:ins w:id="1" w:author="Jane Reporter" w:date="2026-01-02T03:04:05Z"><w:r><w:t>The story text</w:t></w:r></w:ins></w:p></w:body></w:document>"#.utf8)),
            ("word/comments.xml", Data(#"<?xml version="1.0"?><w:comments xmlns:w="w"><w:comment w:id="0" w:author="Jane Reporter" w:initials="JR"><w:p><w:r><w:t>check source</w:t></w:r></w:p></w:comment></w:comments>"#.utf8)),
            ("word/people.xml", Data(#"<?xml version="1.0"?><w15:people xmlns:w15="w15"><w15:person w15:author="Jane Reporter"><w15:presenceInfo w15:providerId="AD" w15:userId="Zurich"/></w15:person></w15:people>"#.utf8)),
        ]
        try require(DocxPage.pack(entries)).write(to: url)
        expect(!MetadataScrubber.remainingMetadata(at: url).isEmpty, "the test document must carry metadata")

        expect(try MetadataScrubber.scrub(url) == .cleaned)
        expect(MetadataScrubber.remainingMetadata(at: url).isEmpty, "\(MetadataScrubber.remainingMetadata(at: url))")
        let after = try require(DocxPage.allEntries(try Data(contentsOf: url)))
        let all = after.compactMap { String(data: $0.data, encoding: .utf8) }.joined()
        let leaked = Self.secrets.filter { all.contains($0) }
        expect(leaked.isEmpty, "leaks \(leaked)")
        expect(all.contains("The story text") && all.contains("check source"), "the content stays")
    }

    func realWordFileStillOpensWithoutAuthor() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("letter.docx")
        let text = NSAttributedString(string: "Interview notes, page one.")
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML,
                                                      .author: "Jane Reporter", .company: "MakerCo", .title: "ModelZ"])
        try data.write(to: url)
        expect(!MetadataScrubber.remainingMetadata(at: url).isEmpty, "macOS must have written the author")
        expect(try MetadataScrubber.scrub(url) == .cleaned)
        var attributes: NSDictionary?
        let back = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: &attributes)
        expect(back.string.contains("Interview notes, page one."), "the document still opens")
        expect(attributes?[NSAttributedString.DocumentAttributeKey.author] == nil, "author: \(String(describing: attributes?[NSAttributedString.DocumentAttributeKey.author]))")
        let all = (DocxPage.allEntries(try Data(contentsOf: url)) ?? []).compactMap { String(data: $0.data, encoding: .utf8) }.joined()
        expect(!all.contains("Jane Reporter") && !all.contains("MakerCo"))
    }

    func pdfTextStaysSelectable() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("text.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = try require(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextAuthor: "Jane Reporter"] as CFDictionary))
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Source protected text", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        ctx.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        expect(try MetadataScrubber.scrub(url) == .cleaned)
        expect(PDFDocument(url: url)?.string?.contains("Source protected text") == true, "text: \(PDFDocument(url: url)?.string ?? "nil")")
        expect(leaks(url).isEmpty)
    }

    func otherTypesAreUntouched() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        let bytes = Data("Jane Reporter".utf8)
        try bytes.write(to: url)
        expect(try MetadataScrubber.scrub(url) == .unsupported)
        expect(try Data(contentsOf: url) == bytes)
    }
}
