import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XToolCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var changingPassword = false
    @State private var renewingKey = false
    @State private var restore = RestoreRequest()

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            PageHeader(title: AppSection.settings.title)
            Form {
                Section("Security") {
                    if model.passwordNeedsUpgrade {
                        HStack {
                            Label("Your password does not meet the current rules.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(XColor.warning)
                            Spacer()
                            Button("Change …") { changingPassword = true }.buttonStyle(.xPrimary)
                        }
                    } else {
                        LabeledContent("Master password") {
                            Button("Change …") { changingPassword = true }
                        }
                    }
                    LabeledContent {
                        Button("Renew …") { renewingKey = true }
                    } label: {
                        Text("Encryption key")
                        Text("Encrypts everything again with a new key, so old copies of the vault no longer fit what is in it.")
                    }
                    Picker("Lock automatically", selection: Binding(get: { model.settings.autoLockMinutes }, set: { model.settings.autoLockMinutes = $0 })) {
                        Text("After 1 minute").tag(1)
                        Text("After 5 minutes").tag(5)
                        Text("After 15 minutes").tag(15)
                        Text("After 30 minutes").tag(30)
                        Text("After 1 hour").tag(60)
                        Text("Never").tag(0)
                    }
                    Toggle(isOn: Binding(get: { model.settings.spellCheck }, set: { model.settings.spellCheck = $0 })) {
                        Text("Spell checking in the Writer")
                        Text("Runs through macOS, so text leaves xTool. Words macOS learns are stored unencrypted.")
                    }
                    Toggle("Hide from screenshots and screen recordings", isOn: Binding(get: { model.settings.screenProtection }, set: {
                        model.settings.screenProtection = $0
                        ScreenGuard.setEnabled($0)
                    }))
                }

                Section {
                    LabeledContent("Backup") {
                        HStack {
                            Button("Create …", action: backup)
                            Button("Restore …") { restore.choose() }
                        }
                    }
                    LabeledContent("All files") {
                        Button("Export …", action: exportAll)
                    }
                    Toggle(isOn: Binding(get: { model.settings.stripMetadata }, set: { model.settings.stripMetadata = $0 })) {
                        Text("Remove metadata when exporting")
                        Text("Photos lose location, camera and dates. PDFs and Office files lose author and editing details. Files in xTool keep their originals. Videos and other types are exported unchanged.")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("A backup stays encrypted and needs the password that was in use when it was created. An export puts the files unencrypted into the chosen folder.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    Picker("Theme", selection: Binding(get: { model.settings.theme }, set: { v in
                        model.settings.theme = v
                        Theme.apply(v)
                    })) {
                        Text("Dark").tag("Dark")
                        Text("Light").tag("Light")
                        Text("Like macOS").tag("System")
                    }
                    .pickerStyle(.segmented)
                    .tint(.gray)
                }

                Section("Vault") {
                    LabeledContent("Location") {
                        HStack {
                            Label(model.location.name, systemImage: model.location.kind == .thisMac ? "laptopcomputer" : "externaldrive")
                                .foregroundStyle(.secondary)
                            if model.location.kind == .drive {
                                Button(model.startedFromDrive ? "Lock and Quit" : "Lock and Eject") { model.lockAndEject() }
                            }
                        }
                    }
                    LabeledContent {
                        Button("Choose Drive …", action: putOnDrive)
                    } label: {
                        Text("Put xTool on a USB stick")
                        Text("Started from a stick, xTool keeps its vault on the stick and works on any Mac.")
                    }
                    if let drive = model.drive, let vault = model.vault {
                        let files = drive.allFiles()
                        LabeledContent("Files", value: "\(files.count) · \(FileTypes.size(files.reduce(0) { $0 + $1.size }))")
                        LabeledContent("Notes", value: "\(vault.index.notes.count)")
                        LabeledContent("Tasks", value: "\(vault.index.boards.reduce(0) { $0 + $1.columns.reduce(0) { $0 + $1.cards.count } })")
                        LabeledContent("Location") {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vault.root]) }
                        }
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        XLogo(size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("xTool \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 13, weight: .medium))
                            Text("AES-256 · Argon2id · no network access").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(isPresented: $renewingKey) { RenewKeySheet() }
        .modifier(RestorePrompt(request: $restore))
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xvault") ?? .data]
        panel.nameFieldStringValue = "xTool-Backup-\(Date().formatted(.iso8601.year().month().day())).xvault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.createBackup(to: url)
    }

    private func putOnDrive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Choose the USB stick or drive for xTool."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let volume = VaultLocation.drive(containing: url) else {
            model.alert = AlertInfo(title: "Not a removable drive", message: "Choose a USB stick or another drive, not a folder on this Mac.")
            return
        }
        model.showAppForDrive(volume)
    }

    private func exportAll() {
        guard let drive = model.drive else { return }
        let ids = drive.children(of: nil).map(\.id)
        guard !ids.isEmpty else {
            model.showToast("There are no files yet.")
            return
        }
        guard let folder = Panels.chooseExportFolder(count: ids.count) else { return }
        // one folder around everything, so nothing mixes with what is already there
        let target = folder.appendingPathComponent("xTool Export \(Date().formatted(.iso8601.year().month().day()))")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            model.exportNodes(ids, to: target)
        } catch {
            model.alert = AlertInfo(title: "Export not possible", message: error.localizedDescription)
        }
    }
}

struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var revealCurrent = false
    @State private var new = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false
    @State private var newKey = true
    @State private var vaultSize: Int64 = 0

    private var canChange: Bool {
        !busy && !current.isEmpty && NewPasswordForm.isValid(password: new, confirmation: confirmation, previous: current)
    }

    var body: some View {
        SheetLayout(title: "Change Master Password", width: 400) {
            VStack(alignment: .leading, spacing: 14) {
                PasswordField(title: "Current Password", text: $current, revealed: $revealCurrent)
                NewPasswordForm(password: $new, confirmation: $confirmation, previous: current, onSubmit: change)
                Toggle(isOn: $newKey) {
                    Text("Also encrypt everything with a new key")
                    Text("Recommended if someone may know your old password: an old copy of the vault then opens nothing. Takes as long as copying \(FileTypes.size(vaultSize)).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Text("Older backups still open with the old password. Create a new backup afterwards and delete the old ones.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(XColor.danger) }
            }
        } buttons: {
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
            Button("Change", action: change).keyboardShortcut(.defaultAction).buttonStyle(.xPrimary).disabled(!canChange)
        }
        .task { vaultSize = await Task.detached { [vault = model.vault] in vault?.renewalSize() ?? 0 }.value }
    }

    private func change() {
        guard canChange, let vault = model.vault else { return }
        busy = true
        error = nil
        let (old, newPassword) = (current, new)
        if newKey {
            // check here, so a typo is answered in the sheet; the renewal checks again
            Task {
                let header = vault.header
                let ok = (try? await Task.detached(priority: .userInitiated) { try Vault.checkPassword(header: header, password: old) }.value) ?? false
                busy = false
                guard ok else { error = "The current password is not correct."; return }
                dismiss()
                model.renewMasterKey(password: old, newPassword: newPassword)
            }
            return
        }
        Task {
            do {
                let ok = try await Task.detached(priority: .userInitiated) { try vault.changePassword(old: old, new: newPassword) }.value
                busy = false
                if ok {
                    model.passwordNeedsUpgrade = false
                    model.showToast("Password changed")
                    dismiss()
                } else {
                    error = "The current password is not correct."
                }
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

/// Asks for the password, then encrypts everything again with a new master key. The password stays the same.
struct RenewKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var revealed = false
    @State private var error: String?
    @State private var busy = false
    @State private var vaultSize: Int64 = 0

    var body: some View {
        SheetLayout(title: "Renew Encryption Key", width: 420) {
            VStack(alignment: .leading, spacing: 14) {
                Text("xTool creates a new random key and encrypts every file, note and task again with it. Your password stays the same.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Do this if someone may have had your password and a copy of the vault, for example a backup or a Time Machine copy. Those old copies then open nothing that is in xTool from now on.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("It takes about as long as copying \(FileTypes.size(vaultSize)) and needs that much free space. If xTool quits or the Mac turns off meanwhile, nothing is lost.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PasswordField(title: "Password", text: $password, revealed: $revealed, onSubmit: start)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(XColor.danger) }
            }
        } buttons: {
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
            Button("Renew Key", action: start).keyboardShortcut(.defaultAction).buttonStyle(.xPrimary).disabled(busy || password.isEmpty)
        }
        .task { vaultSize = await Task.detached { [vault = model.vault] in vault?.renewalSize() ?? 0 }.value }
    }

    private func start() {
        guard !busy, !password.isEmpty, let vault = model.vault else { return }
        busy = true
        error = nil
        let (pw, header) = (password, vault.header)
        Task {
            let ok = (try? await Task.detached(priority: .userInitiated) { try Vault.checkPassword(header: header, password: pw) }.value) ?? false
            busy = false
            guard ok else { error = "The password is not correct."; return }
            dismiss()
            model.renewMasterKey(password: pw)
        }
    }
}
