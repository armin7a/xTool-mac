import AppKit
import Observation
import SwiftUI
import XToolCore

enum AppState { case setup, locked, unlocked }

enum DocKind: String, Codable { case pdf, image, text, office, writer, info }

/// An open file shown as a tab.
struct DocTab: Identifiable, Hashable {
    let id: String
    var kind: DocKind
    var title: String
    var nodeId: String?
    var writer: WriterRequest?
    var dirty = false

    var symbol: String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .office: return "tablecells"
        case .writer: return "doc.text"
        case .info: return "doc"
        }
    }
}

enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case drive, recent, notes, todo, trash, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .drive: return "Files"
        case .recent: return "Recent"
        case .notes: return "Notes"
        case .todo: return "Tasks"
        case .trash: return "Trash"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .drive: return "folder"
        case .recent: return "clock"
        case .notes: return "note.text"
        case .todo: return "checklist"
        case .trash: return "trash"
        case .settings: return "gearshape"
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Toast: Equatable {
    let text: String
    var isError = false
}

/// A long-running job shown in the progress card (see Transfers.swift).
struct TransferState: Equatable {
    var title: String
    var detail = ""
    /// 0…1
    var fraction = 0.0
    var cancellable = true
}

/// App-wide state. The vault index lives in a class (Vault), so views read `revision`
/// to re-render after every change.
@MainActor
@Observable
final class AppModel {
    var state: AppState = Vault.exists(at: Vault.defaultRoot) ? .locked : .setup
    var revision = 0
    var section: AppSection = .drive
    var currentFolderId: String?
    var selection = Set<String>()
    var toast: Toast?
    var alert: AlertInfo?
    var transfer: TransferState?
    var pendingNewNote = false
    var tabs: [DocTab] = []
    /// nil = the section shown in the sidebar
    var activeTabId: String?
    var focusMode = false
    /// The password in use doesn't meet today's rules (it keeps working; Settings suggests changing it).
    var passwordNeedsUpgrade = false
    /// Shown on the lock screen: what happened as the vault locked.
    var lockNotice: String?
    /// A new master key is being made: the window is blocked until it is done.
    var renewingKey = false

    @ObservationIgnored private(set) var vault: Vault?
    @ObservationIgnored private(set) var drive: Drive?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored let autoLock = AutoLock()
    @ObservationIgnored var clipboard: (ids: [String], cut: Bool) = ([], false)
    @ObservationIgnored var cancelToken: CancelToken?

    var isUnlocked: Bool { state == .unlocked }
    var settings: AppSettings {
        get { vault?.index.settings ?? AppSettings() }
        set { vault?.index.settings = newValue; save() }
    }

    init() {
        autoLock.onLock = { [weak self] in self?.lock(.automatic) }
        autoLock.minutes = { [weak self] in self?.vault?.index.settings.autoLockMinutes ?? 1 }
        // a long upload or export counts as activity
        autoLock.isBusy = { [weak self] in self?.transfer != nil }
        autoLock.start()
        ClipboardGuard.shared.start()
    }

    // MARK: lifecycle

    func createVault(password: String) async throws {
        let root = Vault.defaultRoot
        let vault = try await Task.detached(priority: .userInitiated) { try Vault.create(at: root, password: password) }.value
        vault.index.settings.theme = "Dark"
        LoginGuard(vaultRoot: root).reset()
        enter(vault)
    }

    /// Returns false on a wrong password.
    func unlock(password: String) async throws -> Bool {
        let root = Vault.defaultRoot
        let result: (Vault, Bool) = try await Task.detached(priority: .userInitiated) {
            let v = try Vault.open(at: root)
            let unlocked = try v.unlock(password: password)
            if unlocked { v.upgradeKeyProtectionIfNeeded(password: password) }
            return (v, unlocked)
        }.value
        guard result.1 else { return false }
        passwordNeedsUpgrade = !PasswordPolicy.evaluate(password).isAcceptable
        enter(result.0)
        return true
    }

    private func enter(_ vault: Vault) {
        self.vault = vault
        let drive = Drive(vault: vault)
        self.drive = drive
        lockNotice = nil
        moveToCurrentDefaults(vault)
        if drive.purgeTrash() > 0 { try? vault.saveIndex() }
        let recovered = drive.recoverLostContent()
        if recovered > 0 {
            try? vault.saveIndex()
            showToast(recovered == 1 ? "Recovered 1 lost document version" : "Recovered \(recovered) lost document versions")
        }
        if vault.loadedFromIndexBackup {
            alert = AlertInfo(title: "Vault index repaired",
                              message: "The index was damaged. xTool loaded the copy from the previous save. Your very latest changes may be missing.")
        } else if passwordNeedsUpgrade {
            showToast("Your password is weak. You can change it in Settings.")
        }
        Theme.apply(vault.index.settings.theme)
        #if DEBUG
        if !TestTour.enabled { ScreenGuard.setEnabled(vault.index.settings.screenProtection) }
        #else
        ScreenGuard.setEnabled(vault.index.settings.screenProtection)
        #endif
        section = .drive
        currentFolderId = nil
        state = .unlocked
        autoLock.touch()
        changed()
    }

    /// Older vaults once get the stricter defaults. The former automatic lock of 5 minutes was a default, so it follows.
    private func moveToCurrentDefaults(_ vault: Vault) {
        guard vault.index.settings.defaultsVersion < AppSettings.currentDefaultsVersion else { return }
        if vault.index.settings.autoLockMinutes == 5 { vault.index.settings.autoLockMinutes = 1 }
        vault.index.settings.defaultsVersion = AppSettings.currentDefaultsVersion
        try? vault.saveIndex()
    }

    enum LockReason { case user, automatic }

    /// Open documents save themselves first, then the index is written, then the key is wiped.
    func lock(_ reason: LockReason = .user) {
        guard let vault else { return }
        if renewingKey && reason == .user {
            showToast("Please wait until the new key is in place.")
            return
        }
        NotificationCenter.default.post(name: .xtoolWillLock, object: nil)
        saveTask?.cancel()
        do {
            if renewingKey {
                // the window was blocked, so nothing changed since the renewal took its copy of the index
                lockNotice = "Locking interrupted the new key. If it had not finished, nothing was changed: you can start it again in Settings."
            } else {
                try vault.saveIndex()
            }
        } catch {
            // The user can react: stay open rather than lose changes.
            // Sleep or a locked screen can't wait: lock anyway and say so afterwards.
            if reason == .user {
                alert = AlertInfo(title: "Saving failed",
                                  message: "Your latest changes could not be written, so the vault stays open. Please check your free disk space.\n\n\(error.localizedDescription)")
                return
            }
            lockNotice = "Your latest changes could not be saved while locking."
        }
        if transfer?.cancellable == true {
            cancelToken?.cancel()
            lockNotice = lockNotice ?? "The running transfer was cancelled when the vault locked. Finished files are saved."
        }
        vault.waitForWrites()
        vault.lock()
        ClipboardGuard.shared.clearIfOurs()
        ThumbCache.shared.clear()
        tabs = []
        activeTabId = nil
        focusMode = false
        selection = []
        self.vault = nil
        drive = nil
        clipboard = ([], false)
        passwordNeedsUpgrade = false
        toast = nil
        state = Vault.exists(at: Vault.defaultRoot) ? .locked : .setup
        Theme.applyLockScreen()
        revision += 1
    }

    // MARK: changes

    /// Re-render only (no write).
    func changed() { revision += 1 }

    /// Re-render and write the index shortly after (debounced).
    func save() {
        revision += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let vault = self?.vault, vault.isUnlocked else { return }
            vault.saveIndexInBackground { error in
                if error != nil {
                    Task { @MainActor in self?.showToast("Saving failed. Please check your free disk space.", isError: true) }
                }
            }
        }
    }

    func flush() {
        saveTask?.cancel()
        if let vault, vault.isUnlocked { try? vault.saveIndex() }
    }

    func showToast(_ text: String, isError: Bool = false) {
        toast = Toast(text: text, isError: isError)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: isError ? 6_000_000_000 : 3_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: navigation

    func goToFolder(_ id: String?) {
        currentFolderId = id
        section = .drive
        activeTabId = nil
        selection = []
    }

    func show(_ section: AppSection) {
        activeTabId = nil
        self.section = section
        selection = []
        if section == .drive { currentFolderId = nil }
    }

    /// Where new things go: the open folder, or the top level from anywhere else.
    var targetFolderId: String? { section == .drive ? currentFolderId : nil }

    // MARK: tabs

    func openTab(_ tab: DocTab) {
        if let existing = tabs.first(where: { $0.id == tab.id || (tab.nodeId != nil && $0.nodeId == tab.nodeId) }) {
            activeTabId = existing.id
            return
        }
        tabs.append(tab)
        activeTabId = tab.id
    }

    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabId == id { activeTabId = tabs.isEmpty ? nil : tabs[max(0, index - 1)].id }
        if tabs.isEmpty { focusMode = false }
    }

    func updateTab(_ id: String, title: String? = nil, nodeId: String? = nil, dirty: Bool? = nil) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title, tabs[i].title != title { tabs[i].title = title }
        if let nodeId, tabs[i].nodeId != nodeId { tabs[i].nodeId = nodeId }
        if let dirty, tabs[i].dirty != dirty { tabs[i].dirty = dirty }
    }
}

extension Notification.Name {
    /// Posted right before the vault is locked: open documents save themselves and windows close.
    static let xtoolWillLock = Notification.Name("xtool.willLock")
}
