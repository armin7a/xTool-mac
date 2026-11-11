import Combine
import AppKit
import PDFKit
import SwiftUI
import XToolCore
import ZIPFoundation

// MARK: PDF

struct PDFViewerScreen: View {
    let node: Node
    let data: Data

    var body: some View {
        PDFKitView(data: data)
    }
}

struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(data: data)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        view.backgroundColor = .underPageBackgroundColor
        view.pageShadowsEnabled = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

// MARK: Images

struct ImageViewerScreen: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let data: Data
    @State private var current: Node?
    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1

    private var siblings: [Node] {
        guard let drive = model.drive else { return [node] }
        return drive.children(of: node.parentId).filter { FileTypes.category($0) == .image }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let shown = current ?? node
        ZStack {
            Color.black.opacity(0.9)
            if let image {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        let fit = fitSize(image, in: geo.size)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width * zoom, height: fit.height * zoom)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                }
                .gesture(MagnifyGesture()
                    .onChanged { zoom = max(0.2, min(10, baseZoom * $0.magnification)) }
                    .onEnded { _ in baseZoom = zoom })
                .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1.01 ? 1 : 2; baseZoom = zoom } }
            } else {
                Text("This image format cannot be shown.").foregroundStyle(.white.opacity(0.7))
            }
            HStack {
                navButton("chevron.left") { step(-1) }
                Spacer()
                navButton("chevron.right") { step(1) }
            }
            .padding(.horizontal, 14)
            .opacity(siblings.count > 1 ? 1 : 0)
        }
                .onAppear { image = NSImage(data: data) }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .focusable()
    }

    private func fitSize(_ img: NSImage, in available: CGSize) -> CGSize {
        let s = img.size
        let scale = min(1, min(available.width / max(s.width, 1), available.height / max(s.height, 1)))
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 36, height: 52)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        let list = siblings
        guard list.count > 1, let drive = model.drive else { return }
        let shown = current ?? node
        let idx = list.firstIndex { $0.id == shown.id } ?? 0
        let next = list[(idx + delta + list.count) % list.count]
        let vault = drive.vault
        Task {
            let data = await Task.detached { try? vault.readBlob(next.blobId ?? "") }.value
            current = next
            image = data.flatMap(NSImage.init(data:))
            zoom = 1
            baseZoom = 1
            drive.touch(next.id)
        }
    }
}

// MARK: Text

struct TextEditorScreen: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let data: Data
    var tabId: String = ""
    @State private var text = ""
    @State private var dirty = false
    @State private var loaded = false

    var body: some View {
        PrivateTextEditor(text: $text, font: .monospacedSystemFont(ofSize: 13, weight: .regular), inset: NSSize(width: 14, height: 14))
            .background {
                // ⌘S; hidden tabs are disabled, so only the visible one reacts
                Button("", action: { save(announce: true) }).keyboardShortcut("s").opacity(0)
            }
            .onAppear {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                DispatchQueue.main.async { loaded = true }
            }
            .onChange(of: text) { _, _ in if loaded { dirty = true } }
            .onChange(of: dirty) { _, d in model.updateTab(tabId, dirty: d) }
            // saves by itself shortly after the last keystroke
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled, dirty { save(announce: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xtoolWillLock)) { _ in if dirty { save(announce: false) } }
            .onDisappear { if dirty { save(announce: false) } }
    }

    private func save(announce: Bool) {
        guard let drive = model.drive, dirty || announce else { return }
        do {
            if dirty { try drive.updateContent(node.id, Data(text.utf8)) }
            model.save()
            dirty = false
            if announce { model.showToast("Saved") }
        } catch {
            model.showToast("Saving failed", isError: true)
        }
    }
}

// MARK: Files without a preview

/// A file that isn't decrypted for viewing: unknown type, or too large to fit into memory. It can always be exported.
struct FileInfoScreen: View {
    @Environment(AppModel.self) private var model
    let nodeId: String?

    var body: some View {
        let _ = model.revision
        if let node = model.drive?.get(nodeId) {
            let category = FileTypes.category(node)
            let tooLarge = FileTypes.previewLimit(category).map { node.size > $0 } ?? false
            VStack(spacing: 10) {
                Image(systemName: FileTypes.symbol(category)).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text(node.name).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).padding(.top, 6)
                Text("\(FileTypes.describe(node)) · \(FileTypes.size(node.size))").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(message(node: node, tooLarge: tooLarge))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340).padding(.top, 2)
                Button("Export …") { model.exportWithPanel([node.id]) }.buttonStyle(.xPrimary).padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(symbol: "doc", title: "File not available", message: "It was deleted.")
        }
    }

    private func message(node: Node, tooLarge: Bool) -> String {
        if tooLarge { return "Too large for a preview. The file is stored safely. Export it to open it." }
        if node.ext == "doc" { return "The old Word format cannot be shown. Export the file to open it." }
        return "There is no preview for this file type. Export the file to open it."
    }
}

// MARK: Office preview (xlsx / pptx)

struct OfficePreviewScreen: View {
    let node: Node
    let data: Data

    var body: some View {
        let cat = FileTypes.category(node)
        Group {
            switch cat {
            case .excel:
                if let sheets = OfficeReader.sheets(data), !sheets.isEmpty {
                    TabView {
                        ForEach(sheets.indices, id: \.self) { i in
                            SheetGrid(rows: sheets[i].rows).tabItem { Text(sheets[i].name) }
                        }
                    }
                    .padding(12)
                } else { unreadable }
            case .powerpoint:
                if let slides = OfficeReader.slides(data) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(slides.indices, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Slide \(i + 1)").font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(slides[i].enumerated()), id: \.offset) { j, line in
                                        Text(line).font(j == 0 ? .title3.weight(.semibold) : .body)
                                    }
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
                            }
                        }
                        .padding(18)
                    }
                } else { unreadable }
            default:
                FileInfoScreen(nodeId: node.id)
            }
        }
    }

    private var unreadable: some View { FileInfoScreen(nodeId: node.id) }
}

struct SheetGrid: View {
    let rows: [[String]]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        Text("\(r + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 34)
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(rows[r][c]).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(minWidth: 90, alignment: .leading)
                                .border(XColor.line)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

/// Minimal OOXML readers that work fully in memory.
enum OfficeReader {
    struct Sheet { let name: String; let rows: [[String]] }

    private static func entries(_ data: Data) -> [String: Data]? {
        guard let archive = try? Archive(data: data, accessMode: .read, pathEncoding: nil) else { return nil }
        var result: [String: Data] = [:]
        for entry in archive where entry.type == .file && entry.path.hasSuffix(".xml") {
            var d = Data()
            _ = try? archive.extract(entry) { d.append($0) }
            result[entry.path] = d
        }
        return result
    }

    static func sheets(_ data: Data) -> [Sheet]? {
        guard let files = entries(data) else { return nil }
        let shared = files["xl/sharedStrings.xml"].map { XMLText.sharedStrings($0) } ?? []
        let names = files["xl/workbook.xml"].map { XMLText.attributes($0, element: "sheet", attribute: "name") } ?? []
        var sheets: [Sheet] = []
        for i in 1...max(1, names.count) {
            guard let xml = files["xl/worksheets/sheet\(i).xml"] else { continue }
            let rows = XMLText.sheetRows(xml, shared: shared)
            sheets.append(Sheet(name: i - 1 < names.count ? names[i - 1] : "Sheet \(i)", rows: rows))
        }
        return sheets
    }

    static func slides(_ data: Data) -> [[String]]? {
        guard let files = entries(data) else { return nil }
        var result: [[String]] = []
        var i = 1
        while let xml = files["ppt/slides/slide\(i).xml"] {
            result.append(XMLText.paragraphs(xml, paragraph: "a:p", text: "a:t"))
            i += 1
        }
        return result
    }
}

/// Small XMLParser helpers.
final class XMLText: NSObject, XMLParserDelegate {
    private var onStart: ((String, [String: String]) -> Void)?
    private var onEnd: ((String) -> Void)?
    private var onText: ((String) -> Void)?

    private static func run(_ data: Data, start: ((String, [String: String]) -> Void)? = nil, end: ((String) -> Void)? = nil, text: ((String) -> Void)? = nil) {
        let handler = XMLText()
        handler.onStart = start
        handler.onEnd = end
        handler.onText = text
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        onStart?(name, attributes)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { onEnd?(name) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { onText?(string) }

    static func attributes(_ data: Data, element: String, attribute: String) -> [String] {
        var result: [String] = []
        run(data, start: { name, attrs in if name == element, let v = attrs[attribute] { result.append(v) } })
        return result
    }

    static func sharedStrings(_ data: Data) -> [String] {
        var result: [String] = []
        var current = ""
        var inT = false
        run(data, start: { name, _ in
            if name == "si" { current = "" }
            if name == "t" { inT = true }
        }, end: { name in
            if name == "t" { inT = false }
            if name == "si" { result.append(current) }
        }, text: { if inT { current += $0 } })
        return result
    }

    static func sheetRows(_ data: Data, shared: [String]) -> [[String]] {
        var rows: [[String]] = []
        var row: [Int: String] = [:]
        var col = 0
        var type = ""
        var value = ""
        var capture = false
        run(data, start: { name, attrs in
            switch name {
            case "row": row = [:]
            case "c":
                type = attrs["t"] ?? ""
                col = columnIndex(attrs["r"] ?? "A")
                value = ""
            case "v", "t": capture = true
            default: break
            }
        }, end: { name in
            switch name {
            case "v", "t": capture = false
            case "c":
                var v = value
                if type == "s", let i = Int(value), i < shared.count { v = shared[i] }
                if type == "b" { v = value == "1" ? "TRUE" : "FALSE" }
                if col < 60 { row[col] = v }
            case "row":
                let n = (row.keys.max() ?? -1) + 1
                rows.append((0..<n).map { row[$0] ?? "" })
                if rows.count >= 2000 { return }
            default: break
            }
        }, text: { if capture { value += $0 } })
        return rows
    }

    static func paragraphs(_ data: Data, paragraph: String, text tag: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inText = false
        run(data, start: { name, _ in
            if name == paragraph { current = "" }
            if name == tag { inText = true }
        }, end: { name in
            if name == tag { inText = false }
            if name == paragraph, !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        }, text: { if inText { current += $0 } })
        return result
    }

    private static func columnIndex(_ ref: String) -> Int {
        var col = 0
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            col = col * 26 + Int(a - 64)
        }
        return max(0, col - 1)
    }
}
