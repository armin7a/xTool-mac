import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Removes what a file says about its author, device and place, for copies that leave the vault.
///
/// The file inside the vault is never changed: for a journalist the original metadata can be evidence
/// (where and when a photo was taken). Only the exported copy is cleaned.
///
/// - Photos (JPEG, PNG, HEIC, TIFF): GPS position, camera, lens, dates, names, comments, XMP and IPTC.
///   JPEG keeps its compressed data bit for bit; the other formats are re-encoded (PNG and TIFF without loss).
/// - PDF: rebuilt page by page, like "Print to PDF". Author, title, keywords, XMP, attachments, scripts,
///   form fields and links do not survive; annotations become part of the page.
/// - Word, Excel, PowerPoint: document properties (author, company, last editor, times) and the names
///   on comments and tracked changes.
/// Every cleaned file is checked again afterwards. Other types (video, audio, …) are not changed.
public enum MetadataScrubber {
    public enum Outcome: Equatable { case cleaned, unsupported }

    public enum ScrubError: LocalizedError {
        case unreadable, protected, tooLarge, notClean([String])
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .protected: return "The file is protected with a password."
            case .tooLarge: return "The file is too large to clean."
            case .notClean(let left): return "Metadata is still present: \(left.joined(separator: ", "))."
            }
        }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    static let officeExtensions: Set<String> = ["docx", "xlsx", "pptx"]
    /// Office files are rewritten in memory.
    static let officeLimit = 512 << 20

    public static func supports(_ fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return imageExtensions.contains(ext) || officeExtensions.contains(ext) || ext == "pdf"
    }

    /// Cleans the file in place. If that is not possible, it throws and leaves the file as it was.
    @discardableResult
    public static func scrub(_ url: URL) throws -> Outcome {
        let ext = url.pathExtension.lowercased()
        guard supports(ext) else { return .unsupported }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).xtoolclean.\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if imageExtensions.contains(ext) {
            try cleanImage(url, to: tmp)
        } else if ext == "pdf" {
            try cleanPDF(url, to: tmp)
        } else {
            try cleanOffice(url, to: tmp)
        }
        let left = remainingMetadata(at: tmp)
        guard left.isEmpty else { throw ScrubError.notClean(left) }
        guard rename(tmp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return .cleaned
    }

    /// What identifying metadata a file still carries. Empty = clean (or a type this does not check).
    public static func remainingMetadata(at url: URL) -> [String] {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return imageLeftovers(url) }
        if ext == "pdf" { return pdfLeftovers(url) }
        if officeExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url), let entries = DocxPage.allEntries(data) else { return ["unreadable"] }
            return officeLeftovers(entries)
        }
        return []
    }

    // MARK: images

    private static func orientation(_ src: CGImageSource, _ index: Int) -> Int? {
        (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
    }

    private static func cleanImage(_ url: URL, to out: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { throw ScrubError.unreadable }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw ScrubError.unreadable }

        // JPEG: the image data is copied unchanged, only the metadata is replaced by the orientation alone.
        if UTType(type as String)?.conforms(to: .jpeg) == true, count == 1,
           let dst = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            let meta = CGImageMetadataCreateMutable()
            if let o = orientation(src, 0) {
                _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFNumber)
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true]
            if CGImageDestinationCopyImageSource(dst, src, options as CFDictionary, nil), imageLeftovers(out).isEmpty { return }
            try? FileManager.default.removeItem(at: out)
        }

        // Everything else: decode and write again with nothing but the orientation.
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, type, count, nil) else { throw ScrubError.unreadable }
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw ScrubError.unreadable }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
            if let o = orientation(src, i) { properties[kCGImagePropertyOrientation] = o }
            CGImageDestinationAddImage(dst, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else { throw ScrubError.unreadable }
    }

    /// Technical values that describe only the pixels. Anything else counts as metadata.
    private static let harmlessImageKeys: [String: Set<String>] = [
        kCGImagePropertyTIFFDictionary as String: ["Orientation", "Compression", "PhotometricInterpretation", "ResolutionUnit",
                                                   "XResolution", "YResolution", "TileLength", "TileWidth", "PlanarConfiguration"],
        kCGImagePropertyExifDictionary as String: ["ColorSpace", "PixelXDimension", "PixelYDimension"],
        kCGImagePropertyJFIFDictionary as String: ["Version", "JFIFVersion", "XDensity", "YDensity", "DensityUnit", "IsProgressive"],
        kCGImagePropertyPNGDictionary as String: ["InterlaceType", "Gamma", "sRGBIntent", "Chromaticities", "XPixelsPerMeter",
                                                  "YPixelsPerMeter", "PixelsAspectRatio"],
    ]
    private static let harmlessXMPTags: Set<String> = [
        "tiff:Orientation", "tiff:ResolutionUnit", "tiff:XResolution", "tiff:YResolution", "tiff:Compression",
        "tiff:PhotometricInterpretation", "tiff:TileLength", "tiff:TileWidth", "exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension",
    ]

    static func imageLeftovers(_ url: URL) -> [String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return ["unreadable image"] }
        var found = Set<String>()
        for i in 0..<CGImageSourceGetCount(src) {
            let properties = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any] ?? [:]
            for (key, value) in properties where key.hasPrefix("{") {
                guard let allowed = harmlessImageKeys[key] else { found.insert(key); continue }
                let keys = (value as? [String: Any])?.keys.map { $0 } ?? []
                for k in keys where !allowed.contains(k) { found.insert("\(key) \(k)") }
            }
            if let meta = CGImageSourceCopyMetadataAtIndex(src, i, nil), let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
                for tag in tags {
                    let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? "?"
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? "?"
                    if !harmlessXMPTags.contains("\(prefix):\(name)") { found.insert("\(prefix):\(name)") }
                }
            }
        }
        return found.sorted()
    }

    // MARK: PDF

    private static func cleanPDF(_ url: URL, to out: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ScrubError.unreadable }
        guard !doc.isLocked, !doc.isEncrypted else { throw ScrubError.protected }
        guard doc.pageCount > 0 else { throw ScrubError.unreadable }
        guard let context = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ScrubError.unreadable }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { throw ScrubError.unreadable }
            let bounds = page.bounds(for: .cropBox)
            let turned = (page.rotation % 180 + 180) % 180 == 90
            var media = CGRect(x: 0, y: 0, width: turned ? bounds.height : bounds.width, height: turned ? bounds.width : bounds.height)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            page.draw(with: .cropBox, to: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// The info entries Quartz writes itself: the time of the export and the macOS PDF engine.
    private static let harmlessPDFInfo: Set<String> = ["Producer", "CreationDate", "ModDate"]

    static func pdfLeftovers(_ url: URL) -> [String] {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return ["unreadable PDF"] }
        var found: [String] = []
        if let info = doc.info {
            CGPDFDictionaryApplyBlock(info, { key, _, _ in
                let name = String(cString: key)
                if !harmlessPDFInfo.contains(name) { found.append("PDF \(name)") }
                return true
            }, nil)
        }
        if let catalog = doc.catalog {
            for key in ["Metadata", "Names", "AcroForm", "OpenAction", "AA"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog, key, &object) { found.append("PDF \(key)") }
            }
        }
        return found
    }

    // MARK: Office

    private static let emptyCore = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/>"#
    private static let emptyApp = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"/>"#
    private static let emptyCustom = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"/>"#

    /// Attributes that name a person: comments, tracked changes, co-authors (Word, Excel, PowerPoint).
    private static let personAttributes = try! NSRegularExpression(
        pattern: #"\b((?:[A-Za-z0-9]+:)?(?:author|initials|userId|providerId|displayName))="[^"]*""#)
    /// Excel comment authors and PowerPoint comment authors.
    private static let excelAuthor = try! NSRegularExpression(pattern: #"<author>[^<]*</author>"#)
    private static let pptAuthorName = try! NSRegularExpression(pattern: #"(<(?:p:cmAuthor|p188:author)\b[^>]*?\bname=)"[^"]*""#)

    private static func isContentXML(_ path: String) -> Bool {
        (path.hasPrefix("word/") || path.hasPrefix("xl/") || path.hasPrefix("ppt/")) && (path.hasSuffix(".xml") || path.hasSuffix(".rels"))
    }

    private static func cleanOffice(_ url: URL, to out: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= officeLimit else { throw ScrubError.tooLarge }
        let data = try Data(contentsOf: url)
        guard var entries = DocxPage.allEntries(data) else { throw ScrubError.unreadable }
        for i in entries.indices {
            let path = entries[i].path
            switch path {
            case "docProps/core.xml": entries[i].data = Data(emptyCore.utf8)
            case "docProps/app.xml": entries[i].data = Data(emptyApp.utf8)
            case "docProps/custom.xml": entries[i].data = Data(emptyCustom.utf8)
            default:
                guard isContentXML(path), var xml = String(data: entries[i].data, encoding: .utf8) else { continue }
                let before = xml
                xml = replace(personAttributes, in: xml, with: "$1=\"\"")
                xml = replace(excelAuthor, in: xml, with: "<author></author>")
                xml = replace(pptAuthorName, in: xml, with: "$1\"\"")
                if xml != before { entries[i].data = Data(xml.utf8) }
            }
        }
        guard let packed = DocxPage.pack(entries) else { throw ScrubError.unreadable }
        try packed.write(to: out)
    }

    static func officeLeftovers(_ entries: [(path: String, data: Data)]) -> [String] {
        var found: [String] = []
        let filled = try! NSRegularExpression(pattern: #"\b(?:[A-Za-z0-9]+:)?(?:author|initials|userId|providerId|displayName)="[^"]+""#)
        let excel = try! NSRegularExpression(pattern: #"<author>[^<]+</author>"#)
        let ppt = try! NSRegularExpression(pattern: #"<(?:p:cmAuthor|p188:author)\b[^>]*?\bname="[^"]+""#)
        for e in entries {
            guard let xml = String(data: e.data, encoding: .utf8) else { continue }
            switch e.path {
            case "docProps/core.xml", "docProps/app.xml", "docProps/custom.xml":
                // our empty documents are a single self-closing element
                let body = xml.components(separatedBy: "?>").last ?? xml
                if body.contains("</") { found.append(e.path) }
            default:
                guard isContentXML(e.path) else { continue }
                let range = NSRange(xml.startIndex..., in: xml)
                if [filled, excel, ppt].contains(where: { $0.firstMatch(in: xml, range: range) != nil }) { found.append("names in \(e.path)") }
            }
        }
        return found
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
