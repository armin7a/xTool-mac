import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XToolCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var changingPassword = false
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
        .modifier(RestorePrompt(request: $restore))
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xvault") ?? .data]
        panel.nameFieldStringValue = "xTool-Backup-\(Date().formatted(.iso8601.year().month().day())).xvault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.createBackup(to: url)
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

    private var canChange: Bool {
        !busy && !current.isEmpty && NewPasswordForm.isValid(password: new, confirmation: confirmation, previous: current)
    }

    var body: some View {
        SheetLayout(title: "Change Master Password", width: 400) {
            VStack(alignment: .leading, spacing: 14) {
                PasswordField(title: "Current Password", text: $current, revealed: $revealCurrent)
                NewPasswordForm(password: $new, confirmation: $confirmation, previous: current, onSubmit: change)
                Text("Older backups still open with the old password. It is best to create a new one afterwards.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(XColor.danger) }
            }
        } buttons: {
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
            Button("Change", action: change).keyboardShortcut(.defaultAction).buttonStyle(.xPrimary).disabled(!canChange)
        }
    }

    private func change() {
        guard canChange, let vault = model.vault else { return }
        busy = true
        error = nil
        let (old, newPassword) = (current, new)
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
