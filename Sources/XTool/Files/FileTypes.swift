import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import XToolCore

enum FileCategory { case folder, pdf, image, text, word, excel, powerpoint, audio, video, archive, other }

enum FileTypes {
    static let writerExtension = "docx"

    private static let map: [String: FileCategory] = {
        var m: [String: FileCategory] = ["pdf": .pdf]
        for e in ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "ico", "heic", "heif", "jfif"] { m[e] = .image }
        for e in ["txt", "md", "json", "csv", "xml", "log", "ini", "cfg", "yaml", "yml", "cs", "js", "ts", "py", "html", "htm",
                  "css", "sql", "ps1", "bat", "sh", "swift", "java", "cpp", "c", "h", "rtf", "tex"] { m[e] = .text }
        for e in ["docx", "docm", "doc"] { m[e] = .word }
        for e in ["xlsx", "xlsm", "xls"] { m[e] = .excel }
        for e in ["pptx", "ppt"] { m[e] = .powerpoint }
        for e in ["mp3", "wav", "flac", "m4a", "ogg", "aac"] { m[e] = .audio }
        for e in ["mp4", "mov", "mkv", "avi", "webm", "m4v"] { m[e] = .video }
        for e in ["zip", "rar", "7z", "tar", "gz"] { m[e] = .archive }
        return m
    }()

    static func category(_ node: Node) -> FileCategory { node.isFolder ? .folder : map[node.ext] ?? .other }
    static func category(ext: String) -> FileCategory { map[ext.lowercased()] ?? .other }

    static func symbol(_ c: FileCategory) -> String {
        switch c {
        case .folder: return "folder.fill"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .word: return "doc.text"
        case .excel: return "tablecells"
        case .powerpoint: return "rectangle.on.rectangle"
        case .audio: return "music.note"
        case .video: return "film"
        case .archive: return "doc.zipper"
        case .other: return "doc"
        }
    }

    /// One accent for folders, so they are found at a glance. Files stay neutral: their thumbnails bring the colour.
    static func color(_ c: FileCategory) -> Color { c == .folder ? XColor.accent : .secondary }

    /// Above this size a file isn't decrypted into memory for a preview; it opens with its details and an export button.
    /// nil = no preview for this type.
    static func previewLimit(_ c: FileCategory) -> Int64? {
        switch c {
        case .pdf: return 1 << 30
        case .image, .word, .excel, .powerpoint: return 256 << 20
        case .text: return 20 << 20
        default: return nil
        }
    }

    static func describe(_ node: Node) -> String {
        switch category(node) {
        case .folder: return "Ordner"
        case .pdf: return "PDF-Dokument"
        case .image: return "Bild"
        case .text: return "Textdatei"
        case .word: return "Word-Dokument"
        case .excel: return "Excel-Tabelle"
        case .powerpoint: return "PowerPoint"
        case .audio: return "Audio"
        case .video: return "Video"
        case .archive: return "Archiv"
        case .other: return node.ext.isEmpty ? "Datei" : "\(node.ext.uppercased())-Datei"
        }
    }

    static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return f.string(fromByteCount: bytes)
    }

    static func date(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Heute, \(time)" }
        if cal.isDateInYesterday(d) { return "Gestern, \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Decrypted thumbnails, in memory only (cleared on lock).
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 500 }

    func cached(_ blobId: String) -> NSImage? { cache.object(forKey: blobId as NSString) }

    func load(_ blobId: String, vault: Vault) async -> NSImage? {
        if let img = cached(blobId) { return img }
        let data = await Task.detached(priority: .utility) { try? vault.readBlob(blobId) }.value
        guard let data, let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: blobId as NSString)
        return img
    }

    func clear() { cache.removeAllObjects() }
}

enum Thumbnails {
    static let width: CGFloat = 320

    /// JPEG thumbnail of a file on disk, without loading it. Very large files get none.
    static func make(url: URL, size: Int64) -> Data? {
        guard size <= 512 << 20 else { return nil }
        switch FileTypes.category(ext: url.pathExtension) {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return thumbnail(src)
        case .pdf:
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return thumbnail(page)
        default:
            return nil
        }
    }

    /// JPEG thumbnail of content in memory, or nil.
    static func make(data: Data, category: FileCategory) -> Data? {
        switch category {
        case .image:
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return thumbnail(src)
        case .pdf:
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
            return thumbnail(page)
        default:
            return nil
        }
    }

    private static func thumbnail(_ src: CGImageSource) -> Data? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return jpeg(NSBitmapImageRep(cgImage: cg))
    }

    private static func thumbnail(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: width, height: width * bounds.height / max(bounds.width, 1))
        let img = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return jpeg(rep)
    }

    private static func jpeg(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
