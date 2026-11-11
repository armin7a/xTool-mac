import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import XToolCore

/// A Writer tab: existing .docx, or a new document from a template.
struct WriterHost: View {
    @Environment(AppModel.self) private var model
    let request: WriterRequest
    let tabId: String
    @State private var controller: WriterController?
    @State private var error: String?

    var body: some View {
        Group {
            if let controller, model.isUnlocked {
                WriterView(controller: controller)
            } else if let error {
                EmptyState(symbol: "doc.questionmark", title: "The document cannot be opened", message: error)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { load() }
    }

    private func load() {
        guard controller == nil, let drive = model.drive else { return }
        if let id = request.nodeId, let node = drive.get(id) {
            do {
                let data = try drive.readContent(node)
                let name = (node.name as NSString).deletingPathExtension
                if data.isEmpty {
                    controller = WriterController(name: name, folderId: node.parentId, text: DocTemplates.blank(), nodeId: id)
                } else {
                    let (text, ours, page) = try WriterController.load(docx: data)
                    controller = WriterController(name: name, folderId: node.parentId, text: text, nodeId: ours ? id : nil, ours: ours, page: page)
                }
                controller?.tabId = tabId
            } catch {
                self.error = "The file is damaged or protected with a password."
            }
        } else {
            let template = DocTemplates.all.first { $0.id == request.template } ?? DocTemplates.all[0]
            let c = WriterController(name: template.defaultName, folderId: request.folderId, text: template.build())
            c.tabId = tabId
            c.dirty = true
            c.createOnOpen = true
            controller = c
            // the file is created as soon as the editor exists (WriterView.task) – saving earlier wrote an empty file
        }
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case home = "Home", insert = "Insert", layout = "Layout", view = "View", image = "Image"
    var id: String { rawValue }
}

struct WriterView: View {
    @Environment(AppModel.self) private var model
    @Bindable var controller: WriterController
    @State private var ribbon: RibbonTab = .home
    @State private var textColor = Color.black
    @State private var highlight = Color(red: 1, green: 0.88, blue: 0.4)
    @State private var zoom: Double = 1.0
    @State private var showNav = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var showTable = false
    @State private var tableRows = 3
    @State private var tableCols = 3
    @State private var showImagePicker = false
    @State private var showSymbols = false
    @State private var pdfDone: Node?
    @State private var showVersions = false
    private let autosave = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private static let symbols = ["€", "£", "$", "©", "®", "™", "§", "°", "±", "×", "÷", "≈", "≠", "≤", "≥", "∞", "½", "¼", "²", "³",
                                  "µ", "→", "←", "⇒", "✓", "✗", "•", "…", "–", "—", "„", "“", "«", "»", "♥", "★"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ribbonPanel
                .frame(height: 62)
            Rectangle().fill(XColor.line).frame(height: 1)
            if !controller.ours {
                Label("Word file from another app. When you save, xTool creates a copy and leaves the original unchanged.", systemImage: "info.circle")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(XColor.hover)
            }
            HStack(spacing: 0) {
                if showNav { navigation.frame(width: 220) }
                PaperEditor(controller: controller, zoom: zoom, spellCheck: model.settings.spellCheck, onChange: { controller.markDirty(model) })
            }
            statusBar
        }
        .onChange(of: controller.imageSelected) { _, sel in
            if sel { ribbon = .image } else if ribbon == .image { ribbon = .home }
        }
        .alert("Rename Document", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                controller.name = newName
                if let id = controller.nodeId, let drive = model.drive {
                    drive.rename(id, to: newName + ".docx")
                    controller.name = ((drive.get(id)?.name ?? newName) as NSString).deletingPathExtension
                    model.save()
                }
                model.updateTab(controller.tabId, title: controller.name)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("PDF created", isPresented: Binding(get: { pdfDone != nil }, set: { if !$0 { pdfDone = nil } })) {
            Button("Open PDF") { if let n = pdfDone { Opener.open(n, model: model) }; pdfDone = nil }
            Button("OK", role: .cancel) { pdfDone = nil }
        } message: {
            Text("“\(pdfDone?.name ?? "")” is stored encrypted in the same xTool folder.")
        }
        .sheet(isPresented: $showTable) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Insert table").font(.system(size: 15, weight: .semibold))
                Stepper("Rows: \(tableRows)", value: $tableRows, in: 1...50)
                Stepper("Columns: \(tableCols)", value: $tableCols, in: 1...10)
                HStack {
                    Spacer()
                    Button("Cancel") { showTable = false }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                    Button("Insert") { controller.insertTable(rows: tableRows, columns: tableCols); showTable = false }
                        .keyboardShortcut(.defaultAction).buttonStyle(.xPrimary)
                }
            }
            .padding(20).frame(width: 300)
        }
        .sheet(isPresented: $showVersions) {
            if let id = controller.nodeId { VersionsView(nodeId: id) { showVersions = false } }
        }
        .sheet(isPresented: $showImagePicker) {
            VaultImagePicker { node in
                showImagePicker = false
                if let node, let data = try? model.drive?.readContent(node), let img = NSImage(data: data) { controller.insertImage(img) }
            }
        }
        .task {
            // a new document from a template: create its file once the editor holds the text
            guard controller.createOnOpen, controller.nodeId == nil else { return }
            for _ in 0..<20 where controller.textView == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if controller.textView != nil { controller.save(model: model, silent: true) }
        }
        .onReceive(autosave) { _ in if controller.dirty && controller.nodeId != nil { controller.save(model: model, silent: true) } }
        .onReceive(NotificationCenter.default.publisher(for: .xtoolWillLock)) { _ in if controller.dirty { controller.save(model: model, silent: true) } }
        .onDisappear { if controller.dirty && model.isUnlocked { controller.save(model: model, silent: true) } }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Button { newName = controller.name; renaming = true } label: {
                Text(controller.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Rename")
            Text(controller.dirty ? "Saving" : controller.nodeId != nil ? "Saved" : "")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Picker("", selection: $ribbon) {
                ForEach(RibbonTab.allCases.filter { $0 != .image || controller.imageSelected }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .tint(.gray)
            .frame(maxWidth: controller.imageSelected ? 330 : 270)
            Spacer()
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { controller.textView?.undoManager?.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { controller.textView?.undoManager?.redo() }
            IconButton(symbol: "clock.arrow.circlepath", help: "Versions") {
                if controller.dirty { controller.save(model: model, silent: true) }
                if controller.nodeId != nil { showVersions = true } else { model.showToast("The document has not been saved yet.") }
            }
            Button { controller.save(model: model) } label: { EmptyView() }
                .keyboardShortcut("s").opacity(0).frame(width: 0)
            Button("Save as PDF", action: exportPdf)
                .buttonStyle(.xQuiet)
                .keyboardShortcut("p")
                .help("Save as a PDF in the same xTool folder")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    // MARK: ribbon

    @ViewBuilder private var ribbonPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                switch ribbon {
                case .home: homeRibbon
                case .insert: insertRibbon
                case .layout: layoutRibbon
                case .view: viewRibbon
                case .image: imageRibbon
                }
            }
            .padding(.horizontal, 8).padding(.top, 7)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .tint(.primary)
    }

    @ViewBuilder private var homeRibbon: some View {
        group("Font") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Menu("Typeface") {
                        ForEach(["Calibri", "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Avenir Next", "Menlo", "Courier New", "Verdana"], id: \.self) { f in
                            Button(f) { controller.setFontFamily(f) }
                        }
                        Divider()
                        Button("All Fonts … (⌘T)") { NSFontManager.shared.orderFrontFontPanel(nil) }
                    }
                    .frame(width: 100)
                    Menu("Size") {
                        ForEach([8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72], id: \.self) { s in Button("\(s) pt") { controller.setFontSize(CGFloat(s)) } }
                    }
                    .frame(width: 70)
                    tool("textformat.size.larger", "Bigger") { controller.growFont(1) }
                    tool("textformat.size.smaller", "Smaller") { controller.growFont(-1) }
                    Menu {
                        Button("UPPERCASE") { controller.changeCase(0) }
                        Button("kleinbuchstaben") { controller.changeCase(1) }
                        Button("Capitalize Each Word") { controller.changeCase(2) }
                    } label: { Image(systemName: "textformat") }
                    .frame(width: 40)
                    .help("Change case")
                }
                HStack(spacing: 2) {
                    tool("bold", "Bold (⌘B)") { controller.toggleTrait(.boldFontMask) }.keyboardShortcut("b")
                    tool("italic", "Italic (⌘I)") { controller.toggleTrait(.italicFontMask) }.keyboardShortcut("i")
                    tool("underline", "Underline (⌘U)") { controller.toggleAttribute(.underlineStyle) }.keyboardShortcut("u")
                    tool("strikethrough", "Strikethrough") { controller.toggleAttribute(.strikethroughStyle) }
                    tool("textformat.superscript", "Superscript") { controller.raiseText() }
                    tool("textformat.subscript", "Subscript") { controller.lowerText() }
                    ColorPicker("", selection: $textColor).labelsHidden().frame(width: 26)
                        .onChange(of: textColor) { _, c in controller.setColor(NSColor(c), key: .foregroundColor) }
                        .help("Text color")
                    tool("highlighter", "Highlight") { controller.setColor(NSColor(highlight), key: .backgroundColor) }
                    tool("eraser", "Remove highlight") { controller.setColor(nil, key: .backgroundColor) }
                    tool("paintbrush", controller.painterArmed ? "Copying format: now select text" : "Copy format") { controller.armPainter() }
                        .foregroundStyle(controller.painterArmed ? XColor.accent : Color.primary)
                    tool("clear", "Clear formatting") { controller.clearFormatting() }
                }
            }
        }
        group("Paragraph") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Menu {
                        Button("● Bullet") { controller.toggleList(.disc) }
                        Button("○ Circle") { controller.toggleList(.circle) }
                        Button("■ Square") { controller.toggleList(.square) }
                        Button("– Dash") { controller.toggleList(.hyphen) }
                    } label: { Image(systemName: "list.bullet") }.frame(width: 40).help("Bulleted list")
                    Menu {
                        Button("1. 2. 3.") { controller.toggleList(.decimal) }
                        Button("a. b. c.") { controller.toggleList(.lowercaseAlpha) }
                        Button("A. B. C.") { controller.toggleList(.uppercaseAlpha) }
                        Button("i. ii. iii.") { controller.toggleList(.lowercaseRoman) }
                        Button("I. II. III.") { controller.toggleList(.uppercaseRoman) }
                    } label: { Image(systemName: "list.number") }.frame(width: 40).help("Numbered list")
                    tool("decrease.indent", "Decrease indent") { controller.indent(-18) }
                    tool("increase.indent", "Increase indent") { controller.indent(18) }
                    Menu {
                        ForEach([1.0, 1.15, 1.5, 2.0, 3.0], id: \.self) { f in Button(String(format: "%.2f", f)) { controller.lineSpacing(f) } }
                    } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }.frame(width: 40).help("Line spacing")
                }
                HStack(spacing: 2) {
                    tool("text.alignleft", "Align left") { controller.align(.left) }
                    tool("text.aligncenter", "Center") { controller.align(.center) }
                    tool("text.alignright", "Align right") { controller.align(.right) }
                    tool("text.justify", "Justify") { controller.align(.justified) }
                    Menu {
                        Button("No Spacing") { controller.paragraphSpacing(before: 0, after: 0) }
                        Button("Space After: 6 pt") { controller.paragraphSpacing(before: nil, after: 6) }
                        Button("Space After: 12 pt") { controller.paragraphSpacing(before: nil, after: 12) }
                        Button("Space Before: 12 pt") { controller.paragraphSpacing(before: 12, after: nil) }
                    } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }.frame(width: 40).help("Paragraph spacing")
                }
            }
        }
        group("Styles") {
            LazyHGrid(rows: [GridItem(.fixed(22)), GridItem(.fixed(22))], spacing: 2) {
                ForEach(DocStyle.all) { s in
                    Button { controller.applyStyle(s) } label: {
                        Text(s.name).font(.system(size: min(15, max(11, s.size * 0.8)), weight: s.bold ? .semibold : .regular)).italic(s.italic)
                            .foregroundStyle(.primary)
                            .frame(width: 104, alignment: .leading).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        group("Edit") {
            VStack(alignment: .leading, spacing: 4) {
                Button { controller.showFind() } label: { Label("Find", systemImage: "magnifyingglass") }.buttonStyle(.borderless).keyboardShortcut("f")
                Button { controller.showFind(replace: true) } label: { Label("Replace", systemImage: "arrow.left.arrow.right") }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var insertRibbon: some View {
        group("Illustrations") {
            HStack(spacing: 4) {
                Menu {
                    Button("From xTool …") { showImagePicker = true }
                    Button("From This Mac …", action: pickImageFromMac)
                } label: { bigLabel("Image", "photo.badge.plus") }.frame(width: 64)
                big("Table", "tablecells.badge.ellipsis") { showTable = true }
            }
        }
        group("Pages") {
            big("Table of\nContents", "list.bullet.indent") { controller.insertTableOfContents() }
        }
        group("Text") {
            HStack(spacing: 4) {
                Menu {
                    ForEach([Date().formatted(date: .long, time: .omitted), Date().formatted(date: .numeric, time: .omitted),
                             Date().formatted(date: .complete, time: .omitted), Date().formatted(date: .numeric, time: .shortened)], id: \.self) { d in
                        Button(d) { controller.insertText(d) }
                    }
                } label: { bigLabel("Date", "calendar") }.frame(width: 64)
                big("Symbol", "character") { showSymbols = true }
                    .popover(isPresented: $showSymbols) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 4) {
                            ForEach(Self.symbols, id: \.self) { s in
                                Button(s) { controller.insertText(s); showSymbols = false }.buttonStyle(.borderless).font(.title3)
                            }
                        }
                        .padding(10)
                    }
            }
        }
        group("Header and Footer") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Header", text: $controller.page.header).frame(width: 200).onSubmit { controller.applyPage(); controller.markDirty(model) }
                HStack {
                    TextField("Footer", text: $controller.page.footer).frame(width: 140).onSubmit { controller.applyPage(); controller.markDirty(model) }
                    Toggle("Page numbers", isOn: $controller.page.pageNumbers).toggleStyle(.checkbox)
                }
            }
            .onChange(of: controller.page) { _, _ in controller.applyPage(); controller.markDirty(model) }
        }
    }

    @ViewBuilder private var layoutRibbon: some View {
        group("Page Setup") {
            HStack(spacing: 8) {
                Picker("Format", selection: $controller.page.format) { ForEach(PageSetup.formats, id: \.self) { Text($0).tag($0) } }.frame(width: 120)
                Picker("Orientation", selection: $controller.page.landscape) { Text("Portrait").tag(false); Text("Landscape").tag(true) }.frame(width: 200)
                Menu("Margins") {
                    ForEach(PageSetup.marginPresets, id: \.name) { m in
                        Button("\(m.name) · \(m.top.formatted()) / \(m.bottom.formatted()) / \(m.left.formatted()) / \(m.right.formatted()) cm") {
                            controller.page.top = m.top; controller.page.bottom = m.bottom; controller.page.left = m.left; controller.page.right = m.right
                        }
                    }
                }
                .frame(width: 120)
            }
            .onChange(of: controller.page) { _, _ in controller.applyPage(); controller.markDirty(model) }
        }
        group("Info") {
            Text("\(controller.page.format) · \(controller.page.landscape ? "landscape" : "portrait") · margins \(controller.page.left.formatted()) cm")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var viewRibbon: some View {
        group("Show") {
            Toggle("Outline", isOn: $showNav).toggleStyle(.button)
        }
        group("Zoom") {
            HStack {
                Button("100 %") { zoom = 1 }
                Button("Page Width") { zoom = 1.25 }
            }
        }
        group("Window") {
            Button { model.focusMode.toggle() } label: { Label("Focus Mode", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
    }

    @ViewBuilder private var imageRibbon: some View {
        group("Size (width of the text area)") {
            HStack(spacing: 4) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    Button("\(Int(f * 100)) %") { controller.resizeImage(fraction: f); controller.markDirty(model) }
                }
            }
        }
        group("Alignment") {
            HStack(spacing: 2) {
                tool("text.alignleft", "Left") { controller.alignImage(.left) }
                tool("text.aligncenter", "Center") { controller.alignImage(.center) }
                tool("text.alignright", "Right") { controller.alignImage(.right) }
            }
        }
        group("Arrange") {
            HStack(spacing: 2) {
                tool("rotate.right", "Rotate") { controller.rotateImage(); controller.markDirty(model) }
                tool("trash", "Delete") { controller.deleteImage(); controller.markDirty(model) }
            }
        }
        Text("Tip: click and drag an image to move it to another place in the text.")
            .font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading).padding(.leading, 8)
    }

    // MARK: building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            content()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 8)
                .help(title)
            Rectangle().fill(XColor.line).frame(width: 1, height: 44)
        }
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func bigLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption).multilineTextAlignment(.center)
        }
    }

    private func big(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { bigLabel(title, symbol).frame(minWidth: 56) }.buttonStyle(.borderless)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline").font(.system(size: 12, weight: .semibold)).padding(12)
            if controller.headings.isEmpty {
                Text("Give paragraphs the style “Heading 1–3” and they appear here.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            List(Array(controller.headings.enumerated()), id: \.offset) { _, h in
                Button { controller.jump(to: h.range) } label: {
                    Text(h.text).lineLimit(1).fontWeight(h.level == 1 ? .semibold : .regular).padding(.leading, CGFloat(h.level - 1) * 12)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(controller.pageInfo).font(.caption).foregroundStyle(.secondary)
            Text(controller.stats).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text("\(controller.page.format) \(controller.page.landscape ? "landscape" : "portrait")").font(.caption).foregroundStyle(.secondary)
            Slider(value: $zoom, in: 0.5...2.0, step: 0.1).controlSize(.mini).frame(width: 100)
            Text("\(Int(zoom * 100)) %").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 28)
    }

    // MARK: actions

    private func pickImageFromMac() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            controller.insertImage(img)
        }
    }

    private func exportPdf() {
        guard let drive = model.drive else { return }
        if controller.dirty { controller.save(model: model, silent: true) }
        let pdf = controller.pdfData()
        let folder = controller.nodeId.flatMap { drive.get($0)?.parentId } ?? controller.folderId
        do {
            let node = try drive.addFile(in: folder, name: controller.name + ".pdf", content: pdf)
            if let thumb = Thumbnails.make(data: pdf, category: .pdf) { try? drive.setThumbnail(node.id, thumb) }
            model.save()
            pdfDone = drive.get(node.id)
        } catch {
            model.showToast("PDF export failed")
        }
    }
}

/// White paper with an NSTextView: native undo, spell check, find bar, font panel, drag & drop of images.
struct PaperEditor: NSViewRepresentable {
    let controller: WriterController
    let zoom: Double
    let spellCheck: Bool
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.underPageBackgroundColor
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3

        let (tv, storage) = PageTextView.make(page: controller.page)
        tv.appearance = NSAppearance(named: .aqua) // paper is always white
        tv.insertionPointColor = .black
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.allowsSpelling = spellCheck
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.usesFontPanel = true
        tv.usesRuler = true
        tv.typingAttributes = [.font: DocStyle.normal.font, .foregroundColor: NSColor.black]
        storage.setAttributedString(controller.initialText)
        tv.delegate = context.coordinator

        scroll.documentView = tv
        scroll.magnification = 96.0 / 72.0 * zoom
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        controller.textStorage = storage
        controller.textView = tv
        controller.applyPage()
        controller.updateStats()
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let target = 96.0 / 72.0 * zoom
        if abs(scroll.magnification - target) > 0.001 { scroll.magnification = target }
        if let tv = scroll.documentView as? PrivateTextView, tv.allowsSpelling != spellCheck { tv.allowsSpelling = spellCheck }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: WriterController
        let onChange: () -> Void

        init(controller: WriterController, onChange: @escaping () -> Void) {
            self.controller = controller
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            controller.textView?.fitToPages()
            onChange()
            controller.updateStats()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.textView?.fitToPages()
            controller.updatePageInfo()
            controller.refreshImageSelection()
            controller.applyPainterIfArmed()
        }
    }
}

/// Keeps the page centered horizontally when the window is wider than the page.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView, rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        return rect
    }
}

struct VaultImagePicker: View {
    @Environment(AppModel.self) private var model
    let done: (Node?) -> Void
    @State private var selected: String?

    var body: some View {
        let images = model.drive?.allFiles().filter { FileTypes.category($0) == .image } ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an image from xTool").font(.system(size: 15, weight: .semibold))
            if images.isEmpty {
                Text("No images found in xTool.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(images) { node in
                            NodeTile(node: node, selected: selected == node.id)
                                .onTapGesture(count: 2) { done(node) }
                                .onTapGesture { selected = node.id }
                        }
                    }
                }
                .frame(height: 360)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                Button("Insert") { done(selected.flatMap { model.drive?.get($0) }) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.xPrimary)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
