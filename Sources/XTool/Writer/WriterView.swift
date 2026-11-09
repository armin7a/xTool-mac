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
                EmptyState(symbol: "doc.questionmark", title: "Dokument kann nicht geöffnet werden", message: error)
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
                self.error = "Die Datei ist beschädigt oder mit einem Passwort geschützt."
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
    case home = "Start", insert = "Einfügen", layout = "Layout", view = "Ansicht", image = "Bild"
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
                Label("Word-Datei aus einem anderen Programm. Beim Speichern legt xTool eine Kopie an – das Original bleibt unverändert.", systemImage: "info.circle")
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
        .alert("Dokument umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Umbenennen") {
                controller.name = newName
                if let id = controller.nodeId, let drive = model.drive {
                    drive.rename(id, to: newName + ".docx")
                    controller.name = ((drive.get(id)?.name ?? newName) as NSString).deletingPathExtension
                    model.save()
                }
                model.updateTab(controller.tabId, title: controller.name)
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("PDF erstellt", isPresented: Binding(get: { pdfDone != nil }, set: { if !$0 { pdfDone = nil } })) {
            Button("PDF öffnen") { if let n = pdfDone { Opener.open(n, model: model) }; pdfDone = nil }
            Button("OK", role: .cancel) { pdfDone = nil }
        } message: {
            Text("„\(pdfDone?.name ?? "")“ liegt verschlüsselt im selben xTool-Ordner.")
        }
        .sheet(isPresented: $showTable) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tabelle einfügen").font(.system(size: 15, weight: .semibold))
                Stepper("Zeilen: \(tableRows)", value: $tableRows, in: 1...50)
                Stepper("Spalten: \(tableCols)", value: $tableCols, in: 1...10)
                HStack {
                    Spacer()
                    Button("Abbrechen") { showTable = false }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                    Button("Einfügen") { controller.insertTable(rows: tableRows, columns: tableCols); showTable = false }
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
            .help("Umbenennen")
            Text(controller.dirty ? "Wird gespeichert" : controller.nodeId != nil ? "Gespeichert" : "")
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
            IconButton(symbol: "arrow.uturn.backward", help: "Rückgängig (⌘Z)") { controller.textView?.undoManager?.undo() }
            IconButton(symbol: "arrow.uturn.forward", help: "Wiederholen (⇧⌘Z)") { controller.textView?.undoManager?.redo() }
            IconButton(symbol: "clock.arrow.circlepath", help: "Versionen") {
                if controller.dirty { controller.save(model: model, silent: true) }
                if controller.nodeId != nil { showVersions = true } else { model.showToast("Das Dokument wurde noch nicht gespeichert.") }
            }
            Button { controller.save(model: model) } label: { EmptyView() }
                .keyboardShortcut("s").opacity(0).frame(width: 0)
            Button("Als PDF", action: exportPdf)
                .buttonStyle(.xQuiet)
                .keyboardShortcut("p")
                .help("Als PDF in denselben xTool-Ordner speichern")
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
        group("Schrift") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Menu("Schriftart") {
                        ForEach(["Calibri", "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Avenir Next", "Menlo", "Courier New", "Verdana"], id: \.self) { f in
                            Button(f) { controller.setFontFamily(f) }
                        }
                        Divider()
                        Button("Alle Schriften … (⌘T)") { NSFontManager.shared.orderFrontFontPanel(nil) }
                    }
                    .frame(width: 100)
                    Menu("Größe") {
                        ForEach([8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72], id: \.self) { s in Button("\(s) pt") { controller.setFontSize(CGFloat(s)) } }
                    }
                    .frame(width: 70)
                    tool("textformat.size.larger", "Größer") { controller.growFont(1) }
                    tool("textformat.size.smaller", "Kleiner") { controller.growFont(-1) }
                    Menu {
                        Button("GROSSBUCHSTABEN") { controller.changeCase(0) }
                        Button("kleinbuchstaben") { controller.changeCase(1) }
                        Button("Erster Buchstabe Groß") { controller.changeCase(2) }
                    } label: { Image(systemName: "textformat") }
                    .frame(width: 40)
                    .help("Groß-/Kleinschreibung")
                }
                HStack(spacing: 2) {
                    tool("bold", "Fett (⌘B)") { controller.toggleTrait(.boldFontMask) }.keyboardShortcut("b")
                    tool("italic", "Kursiv (⌘I)") { controller.toggleTrait(.italicFontMask) }.keyboardShortcut("i")
                    tool("underline", "Unterstrichen (⌘U)") { controller.toggleAttribute(.underlineStyle) }.keyboardShortcut("u")
                    tool("strikethrough", "Durchgestrichen") { controller.toggleAttribute(.strikethroughStyle) }
                    tool("textformat.superscript", "Hochgestellt") { controller.raiseText() }
                    tool("textformat.subscript", "Tiefgestellt") { controller.lowerText() }
                    ColorPicker("", selection: $textColor).labelsHidden().frame(width: 26)
                        .onChange(of: textColor) { _, c in controller.setColor(NSColor(c), key: .foregroundColor) }
                        .help("Schriftfarbe")
                    tool("highlighter", "Markieren") { controller.setColor(NSColor(highlight), key: .backgroundColor) }
                    tool("eraser", "Markierung entfernen") { controller.setColor(nil, key: .backgroundColor) }
                    tool("paintbrush", controller.painterArmed ? "Format wird übertragen – jetzt Text markieren" : "Format übertragen") { controller.armPainter() }
                        .foregroundStyle(controller.painterArmed ? XColor.accent : Color.primary)
                    tool("clear", "Formatierung löschen") { controller.clearFormatting() }
                }
            }
        }
        group("Absatz") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    Menu {
                        Button("● Punkt") { controller.toggleList(.disc) }
                        Button("○ Kreis") { controller.toggleList(.circle) }
                        Button("■ Quadrat") { controller.toggleList(.square) }
                        Button("– Strich") { controller.toggleList(.hyphen) }
                    } label: { Image(systemName: "list.bullet") }.frame(width: 40).help("Aufzählung")
                    Menu {
                        Button("1. 2. 3.") { controller.toggleList(.decimal) }
                        Button("a. b. c.") { controller.toggleList(.lowercaseAlpha) }
                        Button("A. B. C.") { controller.toggleList(.uppercaseAlpha) }
                        Button("i. ii. iii.") { controller.toggleList(.lowercaseRoman) }
                        Button("I. II. III.") { controller.toggleList(.uppercaseRoman) }
                    } label: { Image(systemName: "list.number") }.frame(width: 40).help("Nummerierung")
                    tool("decrease.indent", "Einzug verkleinern") { controller.indent(-18) }
                    tool("increase.indent", "Einzug vergrößern") { controller.indent(18) }
                    Menu {
                        ForEach([1.0, 1.15, 1.5, 2.0, 3.0], id: \.self) { f in Button(String(format: "%.2f", f)) { controller.lineSpacing(f) } }
                    } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }.frame(width: 40).help("Zeilenabstand")
                }
                HStack(spacing: 2) {
                    tool("text.alignleft", "Linksbündig") { controller.align(.left) }
                    tool("text.aligncenter", "Zentriert") { controller.align(.center) }
                    tool("text.alignright", "Rechtsbündig") { controller.align(.right) }
                    tool("text.justify", "Blocksatz") { controller.align(.justified) }
                    Menu {
                        Button("Kein Abstand") { controller.paragraphSpacing(before: 0, after: 0) }
                        Button("Abstand nach: 6 pt") { controller.paragraphSpacing(before: nil, after: 6) }
                        Button("Abstand nach: 12 pt") { controller.paragraphSpacing(before: nil, after: 12) }
                        Button("Abstand vor: 12 pt") { controller.paragraphSpacing(before: 12, after: nil) }
                    } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }.frame(width: 40).help("Absatzabstand")
                }
            }
        }
        group("Formatvorlagen") {
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
        group("Bearbeiten") {
            VStack(alignment: .leading, spacing: 4) {
                Button { controller.showFind() } label: { Label("Suchen", systemImage: "magnifyingglass") }.buttonStyle(.borderless).keyboardShortcut("f")
                Button { controller.showFind(replace: true) } label: { Label("Ersetzen", systemImage: "arrow.left.arrow.right") }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var insertRibbon: some View {
        group("Illustrationen") {
            HStack(spacing: 4) {
                Menu {
                    Button("Aus xTool …") { showImagePicker = true }
                    Button("Vom Mac …", action: pickImageFromMac)
                } label: { bigLabel("Bild", "photo.badge.plus") }.frame(width: 64)
                big("Tabelle", "tablecells.badge.ellipsis") { showTable = true }
            }
        }
        group("Seiten") {
            big("Inhalts-\nverzeichnis", "list.bullet.indent") { controller.insertTableOfContents() }
        }
        group("Text") {
            HStack(spacing: 4) {
                Menu {
                    ForEach([Date().formatted(date: .long, time: .omitted), Date().formatted(date: .numeric, time: .omitted),
                             Date().formatted(date: .complete, time: .omitted), Date().formatted(date: .numeric, time: .shortened)], id: \.self) { d in
                        Button(d) { controller.insertText(d) }
                    }
                } label: { bigLabel("Datum", "calendar") }.frame(width: 64)
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
        group("Kopf- und Fußzeile") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Kopfzeile", text: $controller.page.header).frame(width: 200).onSubmit { controller.applyPage(); controller.markDirty(model) }
                HStack {
                    TextField("Fußzeile", text: $controller.page.footer).frame(width: 140).onSubmit { controller.applyPage(); controller.markDirty(model) }
                    Toggle("Seitenzahlen", isOn: $controller.page.pageNumbers).toggleStyle(.checkbox)
                }
            }
            .onChange(of: controller.page) { _, _ in controller.applyPage(); controller.markDirty(model) }
        }
    }

    @ViewBuilder private var layoutRibbon: some View {
        group("Seite einrichten") {
            HStack(spacing: 8) {
                Picker("Format", selection: $controller.page.format) { ForEach(PageSetup.formats, id: \.self) { Text($0).tag($0) } }.frame(width: 120)
                Picker("Ausrichtung", selection: $controller.page.landscape) { Text("Hochformat").tag(false); Text("Querformat").tag(true) }.frame(width: 200)
                Menu("Seitenränder") {
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
            Text("\(controller.page.format) · \(controller.page.landscape ? "quer" : "hoch") · Ränder \(controller.page.left.formatted()) cm")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var viewRibbon: some View {
        group("Anzeigen") {
            Toggle("Gliederung", isOn: $showNav).toggleStyle(.button)
        }
        group("Zoom") {
            HStack {
                Button("100 %") { zoom = 1 }
                Button("Seitenbreite") { zoom = 1.25 }
            }
        }
        group("Fenster") {
            Button { model.focusMode.toggle() } label: { Label("Fokusmodus", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
    }

    @ViewBuilder private var imageRibbon: some View {
        group("Größe (Breite des Textbereichs)") {
            HStack(spacing: 4) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    Button("\(Int(f * 100)) %") { controller.resizeImage(fraction: f); controller.markDirty(model) }
                }
            }
        }
        group("Ausrichtung") {
            HStack(spacing: 2) {
                tool("text.alignleft", "Links") { controller.alignImage(.left) }
                tool("text.aligncenter", "Zentriert") { controller.alignImage(.center) }
                tool("text.alignright", "Rechts") { controller.alignImage(.right) }
            }
        }
        group("Anordnen") {
            HStack(spacing: 2) {
                tool("rotate.right", "Drehen") { controller.rotateImage(); controller.markDirty(model) }
                tool("trash", "Löschen") { controller.deleteImage(); controller.markDirty(model) }
            }
        }
        Text("Tipp: Bild anklicken und ziehen verschiebt es an eine andere Textstelle.")
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
            Text("Gliederung").font(.system(size: 12, weight: .semibold)).padding(12)
            if controller.headings.isEmpty {
                Text("Weise Absätzen „Überschrift 1–3“ zu, dann erscheinen sie hier.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
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
            Text("\(controller.page.format) \(controller.page.landscape ? "quer" : "hoch")").font(.caption).foregroundStyle(.secondary)
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
            model.showToast("PDF-Export fehlgeschlagen")
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
            Text("Bild aus xTool wählen").font(.system(size: 15, weight: .semibold))
            if images.isEmpty {
                Text("Keine Bilder in xTool gefunden.").foregroundStyle(.secondary)
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
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
                Button("Einfügen") { done(selected.flatMap { model.drive?.get($0) }) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.xPrimary)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
