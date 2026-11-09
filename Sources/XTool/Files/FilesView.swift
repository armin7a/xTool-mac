import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XToolCore

enum Opener {
    /// Shows a file in the best way it can. Anything without a preview, or too large for one, opens without being decrypted.
    @MainActor
    static func open(_ node: Node, model: AppModel) {
        guard let drive = model.drive else { return }
        if node.isFolder {
            model.goToFolder(node.id)
            return
        }
        drive.touch(node.id)
        model.save()
        let category = FileTypes.category(node)
        func tab(_ kind: DocKind) -> DocTab { DocTab(id: node.id, kind: kind, title: node.name, nodeId: node.id) }
        guard let limit = FileTypes.previewLimit(category), node.size <= limit, node.ext != "doc" else {
            model.openTab(tab(.info))
            return
        }
        switch category {
        case .pdf: model.openTab(tab(.pdf))
        case .image: model.openTab(tab(.image))
        case .text: model.openTab(tab(.text))
        case .word:
            model.openTab(DocTab(id: node.id, kind: .writer, title: (node.name as NSString).deletingPathExtension, nodeId: node.id,
                                 writer: WriterRequest(nodeId: node.id, folderId: node.parentId, template: nil)))
        default: model.openTab(tab(.office))
        }
    }
}

/// Files, recent files and the trash: the same view with different content.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var renameTarget: Node?
    @State private var renameText = ""
    @State private var confirmDelete: [String]?
    @State private var confirmEmptyTrash = false
    @State private var moveTargets: [String]?
    @State private var dropTargeted = false
    @State private var versionsTarget: String?

    private var mode: AppSection { model.section }
    private var selection: Set<String> { model.selection }

    private func sorted(_ nodes: [Node]) -> [Node] {
        let s = model.settings
        func less(_ a: Node, _ b: Node) -> Bool {
            switch s.sortBy {
            case "Modified": return a.modified < b.modified
            case "Size": return a.size < b.size
            case "Type": return a.ext == b.ext ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.ext < b.ext
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let order: (Node, Node) -> Bool = s.sortDescending ? { less($1, $0) } : less
        return nodes.filter(\.isFolder).sorted(by: order) + nodes.filter { !$0.isFolder }.sorted(by: order)
    }

    private var items: [Node] {
        let _ = model.revision
        guard let drive = model.drive else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return sorted(Array(drive.search(q).prefix(500))) }
        switch mode {
        case .recent: return drive.recent(60)
        case .trash: return drive.trashItems().sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        default: return sorted(drive.children(of: model.currentFolderId))
        }
    }

    var body: some View {
        @Bindable var model = model
        let nodes = items
        VStack(spacing: 0) {
            header
            ZStack {
                if nodes.isEmpty {
                    emptyState
                } else if model.settings.gridView && mode != .trash {
                    grid(nodes)
                } else {
                    list(nodes)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous)
                        .strokeBorder(XColor.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .background(XColor.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
                        .overlay(Text("Loslassen zum Hinzufügen").font(.system(size: 13, weight: .medium)))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            if !selection.isEmpty { selectionBar }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Suchen")
        .toolbar { toolbarContent }
        .inspector(isPresented: Binding(get: { model.settings.showDetails }, set: { model.settings.showDetails = $0 })) {
            DetailsPanel(selection: selection, nodes: nodes)
                .inspectorColumnWidth(min: 220, ideal: 250, max: 320)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard mode == .drive, search.isEmpty else { return false }
            let files = urls.filter(\.isFileURL)
            model.importFiles(files, into: model.currentFolderId)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 && mode == .drive }
        .onDeleteCommand {
            let ids = Array(selection)
            guard !ids.isEmpty else { return }
            if mode == .trash { confirmDelete = ids } else { trash(ids) }
        }
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first, let node = model.drive?.get(id) else { return .ignored }
            open(node)
            return .handled
        }
        .onChange(of: model.currentFolderId) { _, _ in model.selection = [] }
        .onChange(of: model.section) { _, _ in model.selection = []; search = "" }
        .alert("Umbenennen", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Umbenennen") {
                if let t = renameTarget { model.drive?.rename(t.id, to: renameText); model.save() }
                renameTarget = nil
            }
            Button("Abbrechen", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Endgültig löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Endgültig löschen", role: .destructive) {
                if let ids = confirmDelete { model.drive?.deletePermanently(ids); model.selection = []; model.save() }
                confirmDelete = nil
            }
        } message: { Text("Das lässt sich nicht rückgängig machen.") }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmEmptyTrash) {
            Button("Leeren", role: .destructive) { model.drive?.emptyTrash(); model.selection = []; model.save() }
        } message: { Text("Das lässt sich nicht rückgängig machen.") }
        .sheet(isPresented: Binding(get: { versionsTarget != nil }, set: { if !$0 { versionsTarget = nil } })) {
            if let id = versionsTarget { VersionsView(nodeId: id) { versionsTarget = nil } }
        }
        .sheet(isPresented: Binding(get: { moveTargets != nil }, set: { if !$0 { moveTargets = nil } })) {
            FolderPicker(exclude: Set(moveTargets ?? [])) { target in
                if let ids = moveTargets, let target {
                    let moved = model.drive?.move(ids, to: target.id.isEmpty ? nil : target.id) ?? 0
                    model.selection = []
                    model.save()
                    model.showToast(moved == 1 ? "Verschoben" : "\(moved) Elemente verschoben")
                }
                moveTargets = nil
            }
        }
    }

    // MARK: header

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            if !search.isEmpty {
                Text("Ergebnisse für „\(search)“").font(.system(size: 15, weight: .semibold)).lineLimit(1)
            } else if mode == .drive {
                let path = model.drive?.path(of: model.currentFolderId) ?? []
                crumb(AppSection.drive.title, id: nil, isLast: path.isEmpty)
                ForEach(path) { folder in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    crumb(folder.name, id: folder.id, isLast: folder.id == path.last?.id)
                }
            } else {
                Text(mode.title).font(.system(size: 15, weight: .semibold))
                if mode == .trash { Text("Wird nach 30 Tagen gelöscht").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4) }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private func crumb(_ title: String, id: String?, isLast: Bool) -> some View {
        Button(title) { model.goToFolder(id) }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: isLast ? .semibold : .regular))
            .foregroundStyle(isLast ? .primary : .secondary)
            .lineLimit(1)
            .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: id) }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if mode == .trash {
                Button { confirmEmptyTrash = true } label: { Label("Papierkorb leeren", systemImage: "trash.slash") }
                    .help("Papierkorb leeren")
                    .disabled(items.isEmpty)
            } else {
                Menu {
                    Picker("Sortieren nach", selection: Binding(get: { model.settings.sortBy }, set: { model.settings.sortBy = $0 })) {
                        Text("Name").tag("Name")
                        Text("Änderungsdatum").tag("Modified")
                        Text("Größe").tag("Size")
                        Text("Typ").tag("Type")
                    }
                    .pickerStyle(.inline)
                    Toggle("Absteigend", isOn: Binding(get: { model.settings.sortDescending }, set: { model.settings.sortDescending = $0 }))
                } label: { Label("Sortieren", systemImage: "arrow.up.arrow.down") }
                .menuIndicator(.hidden)
                .tint(.primary)
                .help("Sortieren")
                Button { model.settings.gridView.toggle() } label: {
                    Label("Ansicht", systemImage: model.settings.gridView ? "list.bullet" : "square.grid.2x2")
                }
                .help(model.settings.gridView ? "Als Liste anzeigen" : "Als Kacheln anzeigen")
            }
            Button { model.settings.showDetails.toggle() } label: { Label("Details", systemImage: "info.circle") }
                .help("Details ein- oder ausblenden")
        }
    }

    /// The actions for the selected elements, where they are expected.
    private var selectionBar: some View {
        let ids = Array(selection)
        return HStack(spacing: 2) {
            Text(ids.count == 1 ? "1 ausgewählt" : "\(ids.count) ausgewählt")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
            Spacer()
            if mode == .trash {
                Button("Wiederherstellen") { restore(ids) }.buttonStyle(.xQuiet)
                Button("Endgültig löschen") { confirmDelete = ids }.buttonStyle(.xQuiet).foregroundStyle(XColor.danger)
            } else {
                Button { model.exportWithPanel(ids) } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.xQuiet)
                    .help("Entschlüsselt in einen Ordner auf dem Mac speichern (⇧⌘E)")
                Button { moveTargets = ids } label: { Label("Verschieben", systemImage: "folder") }.buttonStyle(.xQuiet)
                Button { trash(ids) } label: { Label("Löschen", systemImage: "trash") }.buttonStyle(.xQuiet)
            }
            IconButton(symbol: "xmark", help: "Auswahl aufheben") { model.selection = [] }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(XColor.line).frame(height: 1) }
    }

    // MARK: content

    private func grid(_ nodes: [Node]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)], spacing: 8) {
                ForEach(nodes) { node in
                    NodeTile(node: node, selected: selection.contains(node.id))
                        .onTapGesture(count: 2) { open(node) }
                        .onTapGesture { select(node) }
                        .contextMenu { menu(for: selection.contains(node.id) ? Array(selection) : [node.id]) }
                        .draggable(node.id) {
                            Label(node.name, systemImage: FileTypes.symbol(FileTypes.category(node))).padding(6)
                        }
                        .modifier(FolderDrop(node: node, onDrop: { ids in moveDropped(ids, to: node.id) }))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .contextMenu { if mode == .drive { backgroundMenu } }
    }

    private func list(_ nodes: [Node]) -> some View {
        Table(nodes, selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
            TableColumn("Name") { node in
                HStack(spacing: 8) {
                    Image(systemName: FileTypes.symbol(FileTypes.category(node))).foregroundStyle(FileTypes.color(FileTypes.category(node)))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1)
                        if mode != .drive || !search.isEmpty, let drive = model.drive {
                            Text(locationText(drive, node)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            TableColumn(mode == .trash ? "Gelöscht" : "Geändert") { node in
                Text(FileTypes.date(mode == .trash ? (node.deletedAt ?? node.modified) : node.modified)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Größe") { node in Text(node.isFolder ? "—" : FileTypes.size(node.size)).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 60, ideal: 80)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty { if mode == .drive { backgroundMenu } } else { menu(for: Array(ids)) }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let node = model.drive?.get(id) { open(node) }
        }
    }

    private func locationText(_ drive: Drive, _ node: Node) -> String {
        let path = drive.path(of: node.parentId)
        return ([AppSection.drive.title] + path.map(\.name)).joined(separator: " › ")
    }

    @ViewBuilder private var emptyState: some View {
        switch (mode, search.isEmpty) {
        case (_, false): EmptyState(symbol: "magnifyingglass", title: "Nichts gefunden", message: "Für „\(search)“ gibt es keine Treffer.")
        case (.trash, _): EmptyState(symbol: "trash", title: "Der Papierkorb ist leer", message: "Gelöschte Elemente bleiben hier 30 Tage.")
        case (.recent, _): EmptyState(symbol: "clock", title: "Noch nichts geöffnet", message: "Zuletzt geöffnete Dateien erscheinen hier.")
        default:
            EmptyState(symbol: "tray.and.arrow.down", title: "Noch keine Dateien hier", message: "Zieh Dateien aus dem Finder hierher.") {
                Button("Dateien hinzufügen …") { model.importFiles(Panels.chooseFilesToImport(), into: model.currentFolderId) }.buttonStyle(.xPrimary)
            }
            .contextMenu { backgroundMenu }
        }
    }

    // MARK: menus

    @ViewBuilder private var backgroundMenu: some View {
        Button("Dateien hinzufügen …") { model.importFiles(Panels.chooseFilesToImport(), into: model.currentFolderId) }
        if !model.clipboard.ids.isEmpty {
            Button("Einfügen") { paste(into: model.currentFolderId) }
        }
    }

    @ViewBuilder private func menu(for ids: [String]) -> some View {
        let nodes = ids.compactMap { model.drive?.get($0) }
        if mode == .trash {
            Button { restore(ids) } label: { Label("Wiederherstellen", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { confirmDelete = ids } label: { Label("Endgültig löschen", systemImage: "trash.slash") }
        } else {
            if nodes.count == 1, let n = nodes.first {
                Button { open(n) } label: { Label("Öffnen", systemImage: "arrow.up.forward.app") }
                if mode != .drive || !search.isEmpty {
                    Button { model.goToFolder(n.parentId); model.selection = [n.id] } label: { Label("Speicherort zeigen", systemImage: "folder") }
                }
                Divider()
            }
            Button { model.exportWithPanel(ids) } label: { Label("Exportieren …", systemImage: "square.and.arrow.up") }
            Divider()
            if nodes.count == 1, let n = nodes.first {
                Button { renameText = n.name; renameTarget = n } label: { Label("Umbenennen", systemImage: "pencil") }
                if !n.isFolder {
                    Button { versionsTarget = n.id } label: { Label("Versionen …", systemImage: "clock.arrow.circlepath") }
                }
            }
            Button { model.clipboard = (ids, false); model.showToast(ids.count == 1 ? "Kopiert" : "\(ids.count) Elemente kopiert") } label: { Label("Kopieren", systemImage: "doc.on.doc") }
            Button { model.clipboard = (ids, true); model.showToast(ids.count == 1 ? "Ausgeschnitten" : "\(ids.count) Elemente ausgeschnitten") } label: { Label("Ausschneiden", systemImage: "scissors") }
            if nodes.count == 1, let n = nodes.first, n.isFolder, !model.clipboard.ids.isEmpty {
                Button { paste(into: n.id) } label: { Label("Hier einfügen", systemImage: "doc.on.clipboard") }
            }
            Button { moveTargets = ids } label: { Label("Verschieben …", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { trash(ids) } label: { Label("In den Papierkorb", systemImage: "trash") }
        }
    }

    // MARK: actions

    private func select(_ node: Node) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(node.id) { model.selection.remove(node.id) } else { model.selection.insert(node.id) }
        } else {
            model.selection = [node.id]
        }
    }

    private func open(_ node: Node) {
        if mode == .trash {
            model.showToast("Stelle das Element zuerst wieder her.")
            return
        }
        Opener.open(node, model: model)
        if node.isFolder { search = "" }
    }

    private func trash(_ ids: [String]) {
        model.drive?.trash(ids)
        model.selection = []
        model.save()
        model.showToast(ids.count == 1 ? "In den Papierkorb gelegt" : "\(ids.count) Elemente in den Papierkorb gelegt")
    }

    private func restore(_ ids: [String]) {
        model.drive?.restore(ids)
        model.selection = []
        model.save()
        model.showToast("Wiederhergestellt")
    }

    private func paste(into target: String?) {
        guard let drive = model.drive else { return }
        let ids = model.clipboard.ids.filter { drive.get($0) != nil }
        if model.clipboard.cut {
            drive.move(ids, to: target)
            model.clipboard = ([], false)
            model.save()
        } else {
            model.copyNodes(ids, to: target)
        }
    }

    private func moveDropped(_ ids: [String], to target: String?) -> Bool {
        guard let drive = model.drive, !ids.contains(where: { $0 == target }) else { return false }
        let moved = drive.move(ids.filter { drive.get($0) != nil }, to: target)
        if moved > 0 {
            model.selection = []
            model.save()
            model.showToast(moved == 1 ? "Verschoben" : "\(moved) Elemente verschoben")
        }
        return moved > 0
    }
}

/// Folders accept dragged items.
private struct FolderDrop: ViewModifier {
    let node: Node
    let onDrop: ([String]) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        if node.isFolder {
            content
                .dropDestination(for: String.self) { ids, _ in onDrop(ids) } isTargeted: { targeted = $0 }
                .overlay(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous).strokeBorder(XColor.accent, lineWidth: targeted ? 1.5 : 0))
        } else {
            content
        }
    }
}

struct NodeTile: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        let cat = FileTypes.category(node)
        VStack(spacing: 6) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: FileTypes.symbol(cat)).font(.system(size: 34, weight: .light)).foregroundStyle(FileTypes.color(cat))
                }
            }
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: XRadius.small, style: .continuous))
            VStack(spacing: 1) {
                Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(node.isFolder ? " " : FileTypes.size(node.size)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(8)
        .background(selected ? XColor.accent.opacity(0.14) : (hovering ? XColor.hover : .clear), in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
        .onHover { hovering = $0 }
        .task(id: node.thumbBlobId) {
            guard let id = node.thumbBlobId, let vault = model.vault else { thumb = nil; return }
            thumb = await ThumbCache.shared.load(id, vault: vault)
        }
    }
}

struct DetailsPanel: View {
    @Environment(AppModel.self) private var model
    let selection: Set<String>
    let nodes: [Node]
    @State private var thumb: NSImage?

    var body: some View {
        let _ = model.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let drive = model.drive {
                    let selected = selection.compactMap { drive.get($0) }
                    if selected.count == 1, let n = selected.first {
                        let cat = FileTypes.category(n)
                        ZStack {
                            if let thumb { Image(nsImage: thumb).resizable().scaledToFit() }
                            else { Image(systemName: FileTypes.symbol(cat)).font(.system(size: 44, weight: .light)).foregroundStyle(FileTypes.color(cat)) }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .task(id: n.thumbBlobId) {
                            if let id = n.thumbBlobId, let vault = model.vault { thumb = await ThumbCache.shared.load(id, vault: vault) } else { thumb = nil }
                        }
                        Text(n.name).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                        row("Art", FileTypes.describe(n))
                        row("Größe", FileTypes.size(n.isFolder ? drive.folderSize(n.id) : n.size))
                        if n.isFolder { row("Inhalt", "\(drive.children(of: n.id).count) Elemente") }
                        row("Geändert", n.modified.formatted(date: .abbreviated, time: .shortened))
                        row("Erstellt", n.created.formatted(date: .abbreviated, time: .shortened))
                    } else if selected.count > 1 {
                        Text("\(selected.count) Elemente").font(.system(size: 13, weight: .medium))
                        row("Größe", FileTypes.size(selected.reduce(0) { $0 + ($1.isFolder ? drive.folderSize($1.id) : $1.size) }))
                    } else {
                        Text(drive.get(model.currentFolderId)?.name ?? AppSection.drive.title).font(.system(size: 13, weight: .medium))
                        row("Inhalt", "\(nodes.count) Elemente")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12)).textSelection(.enabled)
        }
    }
}

struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    let exclude: Set<String>
    let done: (Node?) -> Void
    @State private var selected: String = "__root"

    var body: some View {
        SheetLayout(title: "Verschieben nach") {
            List(selection: $selected) {
                Label(AppSection.drive.title, systemImage: "folder").tag("__root")
                if let drive = model.drive {
                    ForEach(folders(drive)) { row in
                        Label(row.node.name, systemImage: "folder")
                            .padding(.leading, CGFloat(row.depth) * 14)
                            .tag(row.node.id)
                    }
                }
            }
            .frame(minHeight: 280)
        } buttons: {
            Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
            Button("Hierhin") {
                if selected == "__root" { done(Node(parentId: nil, name: "", kind: .folder).withId(nil)) } else { done(model.drive?.get(selected)) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.xPrimary)
        }
    }

    private struct FolderRow: Identifiable {
        let node: Node
        let depth: Int
        var id: String { node.id }
    }

    private func folders(_ drive: Drive) -> [FolderRow] {
        var result: [FolderRow] = []
        func walk(_ parent: String?, _ depth: Int) {
            for f in drive.children(of: parent).filter({ $0.isFolder && !exclude.contains($0.id) })
                .sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append(FolderRow(node: f, depth: depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 1)
        return result
    }
}

extension Node {
    /// Root marker for the folder picker (empty id = the top level).
    func withId(_ id: String?) -> Node {
        var copy = self
        copy.id = id ?? ""
        return copy
    }
}
