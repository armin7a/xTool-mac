import Foundation
import ZIPFoundation

/// Page format, margins, header/footer of a Writer document.
public struct PageSetup: Equatable {
    public var format = "A4"
    public var landscape = false
    public var top = 2.5, bottom = 2.0, left = 2.5, right = 2.5   // cm
    public var header = ""
    public var footer = ""
    public var pageNumbers = false

    public init() {}

    public static let formats = ["A4", "A5", "Letter"]
    public static let marginPresets: [(name: String, top: Double, bottom: Double, left: Double, right: Double)] = [
        ("Normal", 2.5, 2.0, 2.5, 2.5), ("Schmal", 1.27, 1.27, 1.27, 1.27), ("Moderat", 2.54, 2.54, 1.91, 1.91),
        ("Breit", 2.54, 2.54, 5.08, 5.08), ("DIN 5008 Brief", 4.5, 2.0, 2.5, 2.0),
    ]

    public var sizeCm: (width: Double, height: Double) {
        let s: (Double, Double) = format == "A5" ? (14.8, 21.0) : format == "Letter" ? (21.59, 27.94) : (21.0, 29.7)
        return landscape ? (s.1, s.0) : s
    }

    public static func pt(_ cm: Double) -> CGFloat { CGFloat(cm / 2.54 * 72) }
    public static func twips(_ cm: Double) -> Int { Int((cm / 2.54 * 1440).rounded()) }
    public static func cm(twips: Double) -> Double { twips / 1440 * 2.54 }

    public var paperSize: NSSize { NSSize(width: PageSetup.pt(sizeCm.width), height: PageSetup.pt(sizeCm.height)) }
    public var contentWidth: CGFloat { PageSetup.pt(sizeCm.width - left - right) }
    public var contentHeight: CGFloat { PageSetup.pt(sizeCm.height - top - bottom) }
}

/// Reads/writes page setup and header/footer inside a .docx – the macOS text system ignores them,
/// so they are patched into the zip after NSAttributedString wrote the document.
///
/// The patched document is always written as a *new*, clean zip ([Content_Types].xml first, no in-place
/// updates). Patching the archive in place produced files that Word for Windows accepted but the macOS
/// text system could not open again.
public enum DocxPage {
    private static let wNs = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let rNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let headerPart = "word/header_xtool.xml", footerPart = "word/footer_xtool.xml"

    public static func read(_ data: Data) -> PageSetup {
        var page = PageSetup()
        guard let files = textEntries(data), let doc = files["word/document.xml"] else { return page }
        let sect = lastMatch(#"<w:sectPr\b.*?</w:sectPr>"#, in: doc) ?? ""
        if let pgSz = firstMatch(#"<w:pgSz\b[^>]*>"#, in: sect) {
            let w = Double(attr("w:w", in: pgSz) ?? "") ?? 11906, h = Double(attr("w:h", in: pgSz) ?? "") ?? 16838
            page.landscape = attr("w:orient", in: pgSz) == "landscape" || w > h
            let shortCm = PageSetup.cm(twips: min(w, h))
            page.format = abs(shortCm - 14.8) < 0.3 ? "A5" : abs(shortCm - 21.59) < 0.2 ? "Letter" : "A4"
        }
        if let pgMar = firstMatch(#"<w:pgMar\b[^>]*>"#, in: sect) {
            func cm(_ key: String, _ fallback: Double) -> Double {
                guard let v = attr(key, in: pgMar), let t = Double(v) else { return fallback }
                return (PageSetup.cm(twips: abs(t)) * 100).rounded() / 100
            }
            page.top = cm("w:top", page.top)
            page.bottom = cm("w:bottom", page.bottom)
            page.left = cm("w:left", page.left)
            page.right = cm("w:right", page.right)
        }
        let rels = files["word/_rels/document.xml.rels"] ?? ""
        func part(for tag: String) -> String? {
            guard let ref = firstMatch("<w:\(tag)Reference\\b[^>]*>", in: sect), let id = attr("r:id", in: ref),
                  let rel = firstMatch("<Relationship\\b[^>]*Id=\"\(id)\"[^>]*>", in: rels), let target = attr("Target", in: rel) else { return nil }
            return files["word/" + target.replacingOccurrences(of: "/word/", with: "")]
        }
        if let header = part(for: "header") { page.header = texts(in: header).joined(separator: " ") }
        if let footer = part(for: "footer") {
            var lines: [String] = []
            for p in allMatches(#"<w:p\b.*?</w:p>"#, in: footer) {
                if p.contains("PAGE") { page.pageNumbers = true } else { let t = texts(in: p).joined(); if !t.isEmpty { lines.append(t) } }
            }
            page.footer = lines.joined(separator: " ")
        }
        return page
    }

    /// Adds page size, margins, header and footer to a .docx written by NSAttributedString.
    /// Returns the input unchanged if anything goes wrong.
    public static func apply(_ data: Data, _ page: PageSetup) -> Data {
        guard var entries = allEntries(data),
              var doc = string(entries, "word/document.xml"),
              var rels = string(entries, "word/_rels/document.xml.rels"),
              var types = string(entries, "[Content_Types].xml") else { return data }

        // never stack our parts twice (e.g. when a patched file is patched again)
        entries.removeAll { $0.path == headerPart || $0.path == footerPart }
        rels = rels.replacingOccurrences(of: #"<Relationship\b[^>]*Id="rIdXtool(Header|Footer)"[^>]*/>"#, with: "", options: .regularExpression)
        types = types.replacingOccurrences(of: #"<Override\b[^>]*PartName="/word/(header|footer)_xtool\.xml"[^>]*/>"#, with: "", options: .regularExpression)

        var refs = ""
        if !page.header.isEmpty {
            entries.append((headerPart, Data(hfXML("hdr", paragraphs: [run(page.header)]).utf8)))
            rels = rels.replacingOccurrences(of: "</Relationships>", with: #"<Relationship Id="rIdXtoolHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header_xtool.xml"/></Relationships>"#)
            types = types.replacingOccurrences(of: "</Types>", with: #"<Override PartName="/word/header_xtool.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/></Types>"#)
            refs += #"<w:headerReference w:type="default" r:id="rIdXtoolHeader"/>"#
        }
        if !page.footer.isEmpty || page.pageNumbers {
            var paragraphs: [String] = []
            if !page.footer.isEmpty { paragraphs.append(run(page.footer)) }
            if page.pageNumbers {
                paragraphs.append(#"<w:pPr><w:jc w:val="right"/></w:pPr>"# + run("Seite ") + #"<w:fldSimple w:instr=" PAGE ">"# + run("1") + "</w:fldSimple>"
                                  + run(" von ") + #"<w:fldSimple w:instr=" NUMPAGES ">"# + run("1") + "</w:fldSimple>")
            }
            entries.append((footerPart, Data(hfXML("ftr", paragraphs: paragraphs).utf8)))
            rels = rels.replacingOccurrences(of: "</Relationships>", with: #"<Relationship Id="rIdXtoolFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer_xtool.xml"/></Relationships>"#)
            types = types.replacingOccurrences(of: "</Types>", with: #"<Override PartName="/word/footer_xtool.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>"#)
            refs += #"<w:footerReference w:type="default" r:id="rIdXtoolFooter"/>"#
        }
        let (w, h) = page.sizeCm
        let orient = page.landscape ? #" w:orient="landscape""# : ""
        let sect = "<w:sectPr>\(refs)<w:pgSz w:w=\"\(PageSetup.twips(w))\" w:h=\"\(PageSetup.twips(h))\"\(orient)/>"
            + "<w:pgMar w:top=\"\(PageSetup.twips(page.top))\" w:right=\"\(PageSetup.twips(page.right))\" w:bottom=\"\(PageSetup.twips(page.bottom))\" "
            + "w:left=\"\(PageSetup.twips(page.left))\" w:header=\"\(PageSetup.twips(max(0.6, page.top * 0.4)))\" "
            + "w:footer=\"\(PageSetup.twips(max(0.6, page.bottom * 0.4)))\" w:gutter=\"0\"/></w:sectPr>"
        // replace the body-level section properties (the last sectPr before </w:body>)
        if let re = try? NSRegularExpression(pattern: #"<w:sectPr\b(?:(?!<w:sectPr).)*?(?:/>|</w:sectPr>)\s*</w:body>"#, options: [.dotMatchesLineSeparators]),
           let last = re.matches(in: doc, range: NSRange(location: 0, length: (doc as NSString).length)).last {
            doc = (doc as NSString).replacingCharacters(in: last.range, with: sect + "</w:body>")
        } else {
            doc = doc.replacingOccurrences(of: "</w:body>", with: sect + "</w:body>")
        }
        if !doc.contains("xmlns:r=") {
            doc = doc.replacingOccurrences(of: "<w:document ", with: "<w:document xmlns:r=\"\(rNs)\" ")
        }
        set(&entries, "word/document.xml", doc)
        set(&entries, "word/_rels/document.xml.rels", rels)
        set(&entries, "[Content_Types].xml", types)
        return pack(entries) ?? data
    }

    /// Repairs a .docx the macOS text system can't open: re-packs it as a clean zip and, if `withoutExtras`,
    /// drops the header/footer parts xTool added (the text itself is kept).
    public static func repaired(_ data: Data, withoutExtras: Bool) -> Data? {
        guard var entries = allEntries(data) else { return nil }
        if withoutExtras {
            entries.removeAll { $0.path == headerPart || $0.path == footerPart }
            if var doc = string(entries, "word/document.xml") {
                doc = doc.replacingOccurrences(of: #"<w:(header|footer)Reference\b[^>]*r:id="rIdXtool(Header|Footer)"[^>]*/>"#, with: "", options: .regularExpression)
                set(&entries, "word/document.xml", doc)
            }
            if var rels = string(entries, "word/_rels/document.xml.rels") {
                rels = rels.replacingOccurrences(of: #"<Relationship\b[^>]*Id="rIdXtool(Header|Footer)"[^>]*/>"#, with: "", options: .regularExpression)
                set(&entries, "word/_rels/document.xml.rels", rels)
            }
            if var types = string(entries, "[Content_Types].xml") {
                types = types.replacingOccurrences(of: #"<Override\b[^>]*PartName="/word/(header|footer)_xtool\.xml"[^>]*/>"#, with: "", options: .regularExpression)
                set(&entries, "[Content_Types].xml", types)
            }
        }
        return pack(entries)
    }

    // MARK: zip

    private typealias Entry = (path: String, data: Data)

    private static func allEntries(_ data: Data) -> [Entry]? {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else { return nil }
        var result: [Entry] = []
        for e in archive where e.type == .file {
            var d = Data()
            guard (try? archive.extract(e, skipCRC32: false) { d.append($0) }) != nil else { return nil }
            result.append((e.path, d))
        }
        return result.isEmpty ? nil : result
    }

    /// A fresh archive: [Content_Types].xml and _rels/.rels first (some readers expect that), deflated, no data descriptors.
    private static func pack(_ entries: [Entry]) -> Data? {
        func rank(_ p: String) -> Int { p == "[Content_Types].xml" ? 0 : p == "_rels/.rels" ? 1 : 2 }
        let ordered = entries.enumerated().sorted { (rank($0.element.path), $0.offset) < (rank($1.element.path), $1.offset) }.map(\.element)
        guard let archive = try? Archive(data: Data(), accessMode: .create, pathEncoding: nil) else { return nil }
        do {
            for (path, bytes) in ordered {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { pos, size in
                    bytes.subdata(in: Int(pos)..<Int(pos) + size)
                }
            }
        } catch {
            return nil
        }
        return archive.data
    }

    private static func string(_ entries: [Entry], _ path: String) -> String? {
        entries.first { $0.path == path }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    private static func set(_ entries: inout [Entry], _ path: String, _ text: String) {
        if let i = entries.firstIndex(where: { $0.path == path }) { entries[i].data = Data(text.utf8) }
        else { entries.append((path, Data(text.utf8))) }
    }

    private static func textEntries(_ data: Data) -> [String: String]? {
        guard let entries = allEntries(data) else { return nil }
        var result: [String: String] = [:]
        for e in entries where e.path.hasSuffix(".xml") || e.path.hasSuffix(".rels") { result[e.path] = String(data: e.data, encoding: .utf8) }
        return result
    }

    // MARK: xml helpers

    private static func hfXML(_ root: String, paragraphs: [String]) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + "<w:\(root) xmlns:w=\"\(wNs)\" xmlns:r=\"\(rNs)\">"
            + paragraphs.map { "<w:p>\($0)</w:p>" }.joined() + "</w:\(root)>"
    }

    private static func run(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return #"<w:r><w:rPr><w:color w:val="6B7280"/><w:sz w:val="18"/></w:rPr><w:t xml:space="preserve">"# + escaped + "</w:t></w:r>"
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? { allMatches(pattern, in: text).first }
    private static func lastMatch(_ pattern: String, in text: String) -> String? { allMatches(pattern, in: text).last }

    private static func attr(_ name: String, in tag: String) -> String? {
        guard let m = firstMatch("\(name)=\"([^\"]*)\"", in: tag), let q = m.firstIndex(of: "\"") else { return nil }
        return String(m[m.index(after: q)...].dropLast())
    }

    private static func texts(in xml: String) -> [String] {
        allMatches(#"<w:t\b[^>]*>[^<]*</w:t>"#, in: xml).map { t in
            let inner = t.replacingOccurrences(of: #"<w:t\b[^>]*>"#, with: "", options: .regularExpression).replacingOccurrences(of: "</w:t>", with: "")
            return inner.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
    }
}
