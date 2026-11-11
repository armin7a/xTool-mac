import SwiftUI
import UniformTypeIdentifiers
import XToolCore

/// Sidebar on the left, the active section or document on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showTemplates = false
    @State private var newFolderName: String?
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if !model.focusMode && !model.tabs.isEmpty { TabStrip() }
                ZStack {
                    // Documents stay alive in the background. A hidden one is disabled, so its shortcuts don't fire.
                    if model.activeTabId == nil { HomeContent() }
                    ForEach(model.tabs) { tab in
                        DocContent(tab: tab)
                            .opacity(model.activeTabId == tab.id ? 1 : 0)
                            .allowsHitTesting(model.activeTabId == tab.id)
                            .disabled(model.activeTabId != tab.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(XColor.canvas)
        }
        .onChange(of: model.focusMode) { _, focus in withAnimation { columns = focus ? .detailOnly : .all } }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button { model.importFiles(Panels.chooseFilesToImport(), into: model.targetFolderId) } label: { Label("Add Files …", systemImage: "plus") }
                    Button { newFolderName = "New Folder" } label: { Label("Folder", systemImage: "folder") }
                    Divider()
                    Button { showTemplates = true } label: { Label("Document", systemImage: "doc.text") }
                    Button(action: newTextFile) { Label("Text File", systemImage: "doc.plaintext") }
                    Button {
                        model.show(.notes)
                        model.pendingNewNote = true
                    } label: { Label("Note", systemImage: "note.text") }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .tint(.primary)
                .help("New")
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { template in
                showTemplates = false
                if let template {
                    model.openTab(DocTab(id: "new-" + UUID().uuidString, kind: .writer, title: template.defaultName,
                                         writer: WriterRequest(nodeId: nil, folderId: model.targetFolderId, template: template.id)))
                }
            }
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderName != nil }, set: { if !$0 { newFolderName = nil } })) {
            TextField("Name", text: Binding(get: { newFolderName ?? "" }, set: { newFolderName = $0 }))
            Button("Create") {
                if let name = newFolderName, let drive = model.drive {
                    let parent = model.targetFolderId
                    drive.createFolder(in: parent, name: name)
                    model.goToFolder(parent)
                    model.save()
                }
                newFolderName = nil
            }
            Button("Cancel", role: .cancel) { newFolderName = nil }
        }
        .task {
            #if DEBUG
            await TestTour.run(model: model)
            #endif
        }
    }

    private func newTextFile() {
        guard let drive = model.drive else { return }
        if let node = try? drive.addFile(in: model.targetFolderId, name: "New Text File.txt", content: Data()) {
            model.save()
            model.openTab(DocTab(id: node.id, kind: .text, title: node.name, nodeId: node.id))
        }
    }
}

/// The section chosen in the sidebar.
struct HomeContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.section {
        case .drive, .recent, .trash: FilesView()
        case .notes: NotesView()
        case .todo: TasksView()
        case .settings: SettingsView()
        }
    }
}

/// The content of one document tab.
struct DocContent: View {
    let tab: DocTab

    var body: some View {
        switch tab.kind {
        case .pdf: ViewerHost(nodeId: tab.nodeId) { node, data in PDFViewerScreen(node: node, data: data) }
        case .image: ViewerHost(nodeId: tab.nodeId) { node, data in ImageViewerScreen(node: node, data: data) }
        case .text: ViewerHost(nodeId: tab.nodeId) { node, data in TextEditorScreen(node: node, data: data, tabId: tab.id) }
        case .office: ViewerHost(nodeId: tab.nodeId) { node, data in OfficePreviewScreen(node: node, data: data) }
        case .writer: WriterHost(request: tab.writer ?? WriterRequest(), tabId: tab.id)
        case .info: FileInfoScreen(nodeId: tab.nodeId)
        }
    }
}

struct TabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                chip(id: nil, title: model.section.title, symbol: model.section.symbol, dirty: false)
                ForEach(model.tabs) { tab in chip(id: tab.id, title: tab.title, symbol: tab.symbol, dirty: tab.dirty) }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(XColor.line).frame(height: 1) }
    }

    private func chip(id: String?, title: String, symbol: String, dirty: Bool) -> some View {
        let active = model.activeTabId == id
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
            if let id {
                if dirty { Circle().fill(XColor.accent).frame(width: 6, height: 6) }
                Button { model.closeTab(id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? XColor.hover : .clear, in: RoundedRectangle(cornerRadius: XRadius.small, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabId = id }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.activeTabId == nil ? Optional(model.section) : nil }, set: {
                if let s = $0 { model.show(s) }
            })) {
                ForEach([AppSection.drive, .recent, .notes, .todo, .trash]) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let drive = model.drive else { return false }
                            switch s {
                            case .drive:
                                let moved = drive.move(ids, to: nil)
                                if moved > 0 { model.save() }
                                return moved > 0
                            case .trash:
                                drive.trash(ids)
                                model.selection = []
                                model.save()
                                return true
                            default:
                                return false
                            }
                        }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 6) {
                if let drive = model.drive {
                    Text(FileTypes.size(drive.totalSize()))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        .padding(.horizontal, 8)
                }
                HStack(spacing: 2) {
                    IconButton(symbol: "lock", help: "Lock (⌃⌘L)") { model.lock() }
                    Spacer()
                    IconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.show(.settings) }
                }
                .overlay(alignment: .topTrailing) {
                    if model.passwordNeedsUpgrade { Circle().fill(XColor.warning).frame(width: 6, height: 6).offset(x: -4, y: 4) }
                }
            }
            .padding(10)
        }
    }
}
