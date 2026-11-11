import AppKit
import SwiftUI
import XToolCore

/// What a Writer tab shows: an existing .docx (nodeId) or a new document from a template.
struct WriterRequest: Codable, Hashable {
    var nodeId: String?
    var folderId: String?
    var template: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let transfer = model?.transfer else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "\(transfer.title). Quit anyway?"
            alert.informativeText = "Files that are already finished are kept."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.cancelToken?.cancel()
            NotificationCenter.default.post(name: .xtoolWillLock, object: nil)
            model?.flush()
            model?.vault?.waitForWrites()
            ClipboardGuard.shared.clearIfOurs()
        }
    }
}

/// One window for everything. Sized for a MacBook: compact toolbar, and it still works on a 13-inch screen split in half.
@main
struct XToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        ProcessHardening.apply()
    }

    var body: some Scene {
        Window("xTool", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 500)
                .tint(XColor.accent)
                .autocorrectionDisabled()
                .modifier(NoWritingTools())
                .onAppear {
                    delegate.model = model
                    Theme.applyLockScreen()
                    ScreenGuard.install()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files …") { addFiles() }
                    .keyboardShortcut("o")
                    .disabled(!model.isUnlocked)
                Button("Export Selection …") { model.exportWithPanel(Array(model.selection)) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.isUnlocked || model.selection.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button(model.focusMode ? "Exit Focus Mode" : "Focus Mode") { model.focusMode.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Divider()
                ForEach(Array([AppSection.drive, .recent, .notes, .todo, .trash].enumerated()), id: \.element) { i, section in
                    Button(section.title) { model.show(section) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                        .disabled(!model.isUnlocked)
                }
                Button(AppSection.settings.title) { model.show(.settings) }
                    .keyboardShortcut(",")
                    .disabled(!model.isUnlocked)
            }
            CommandMenu("Vault") {
                Button("Lock") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!model.isUnlocked)
            }
            CommandMenu("Tabs") {
                Button("Close Tab") { if let id = model.activeTabId { model.closeTab(id) } }
                    .keyboardShortcut("w")
                    .disabled(model.activeTabId == nil)
                Button("Next Tab") { cycle(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { cycle(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            TextFormattingCommands()
        }
    }

    @MainActor
    private func addFiles() {
        let urls = Panels.chooseFilesToImport()
        model.importFiles(urls, into: model.targetFolderId)
    }

    @MainActor
    private func cycle(_ delta: Int) {
        let ids: [String?] = [nil] + model.tabs.map { Optional($0.id) }
        let current = ids.firstIndex(of: model.activeTabId) ?? 0
        model.activeTabId = ids[(current + delta + ids.count) % ids.count]
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            switch model.state {
            case .setup: SetupView()
            case .locked: LoginView()
            case .unlocked: MainView()
            }
            VStack(spacing: 8) {
                if let transfer = model.transfer { TransferCard(transfer: transfer) }
                if let toast = model.toast { ToastView(toast: toast) }
            }
            .padding(.bottom, 18)
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.transfer == nil)
        .animation(.easeInOut(duration: 0.2), value: model.state)
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toast.isError ? XColor.warning : XColor.accent)
            Text(toast.text).font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(XColor.line))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Progress of the running job.
private struct TransferCard: View {
    @Environment(AppModel.self) private var model
    let transfer: TransferState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(transfer.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(transfer.fraction * 100)) %").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                if transfer.cancellable {
                    IconButton(symbol: "xmark", help: "Cancel") { model.cancelToken?.cancel() }
                        .frame(height: 16)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(XColor.line)
                    Capsule().fill(XColor.accent).frame(width: max(4, geo.size.width * transfer.fraction))
                }
            }
            .frame(height: 4)
            if !transfer.detail.isEmpty {
                Text(transfer.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.medium, style: .continuous).strokeBorder(XColor.line))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Loads (decrypts) a node into memory and shows it inside a tab.
struct ViewerHost<Content: View>: View {
    @Environment(AppModel.self) private var model
    let nodeId: String?
    @ViewBuilder let content: (Node, Data) -> Content
    @State private var loaded: (Node, Data)?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded, model.isUnlocked {
                content(loaded.0, loaded.1)
            } else if failed {
                EmptyState(symbol: "lock.doc", title: "File not available", message: "The vault is locked or the file was deleted.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: nodeId) { await load() }
    }

    private func load() async {
        guard let nodeId, let drive = model.drive, let node = drive.get(nodeId) else { failed = true; return }
        let vault = drive.vault
        let data = await Task.detached(priority: .userInitiated) { try? vault.readBlob(node.blobId ?? "") }.value
        if let data { loaded = (node, data) } else if node.size == 0 { loaded = (node, Data()) } else { failed = true }
    }
}
