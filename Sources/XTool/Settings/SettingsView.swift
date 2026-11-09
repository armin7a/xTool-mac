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
                Section("Sicherheit") {
                    if model.passwordNeedsUpgrade {
                        HStack {
                            Label("Dein Passwort erfüllt die aktuellen Kriterien nicht.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(XColor.warning)
                            Spacer()
                            Button("Ändern …") { changingPassword = true }.buttonStyle(.xPrimary)
                        }
                    } else {
                        LabeledContent("Master-Passwort") {
                            Button("Ändern …") { changingPassword = true }
                        }
                    }
                    Picker("Automatisch sperren", selection: Binding(get: { model.settings.autoLockMinutes }, set: { model.settings.autoLockMinutes = $0 })) {
                        Text("Nach 1 Minute").tag(1)
                        Text("Nach 5 Minuten").tag(5)
                        Text("Nach 15 Minuten").tag(15)
                        Text("Nach 30 Minuten").tag(30)
                        Text("Nach 1 Stunde").tag(60)
                        Text("Nie").tag(0)
                    }
                    Toggle(isOn: Binding(get: { model.settings.spellCheck }, set: { model.settings.spellCheck = $0 })) {
                        Text("Rechtschreibprüfung im Writer")
                        Text("Läuft über macOS, Text verlässt dabei xTool. Selbst gelernte Wörter speichert macOS unverschlüsselt.")
                    }
                    Toggle("Aus Bildschirmaufnahmen ausblenden", isOn: Binding(get: { model.settings.screenProtection }, set: {
                        model.settings.screenProtection = $0
                        ScreenGuard.setEnabled($0)
                    }))
                }

                Section {
                    LabeledContent("Sicherung") {
                        HStack {
                            Button("Erstellen …", action: backup)
                            Button("Einspielen …") { restore.choose() }
                        }
                    }
                    LabeledContent("Alle Dateien") {
                        Button("Exportieren …", action: exportAll)
                    }
                } header: {
                    Text("Daten")
                } footer: {
                    Text("Eine Sicherung bleibt verschlüsselt und braucht das Passwort, das beim Erstellen galt. Beim Export liegen die Dateien unverschlüsselt im gewählten Ordner.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Darstellung") {
                    Picker("Erscheinungsbild", selection: Binding(get: { model.settings.theme }, set: { v in
                        model.settings.theme = v
                        Theme.apply(v)
                    })) {
                        Text("Dunkel").tag("Dark")
                        Text("Hell").tag("Light")
                        Text("Wie macOS").tag("System")
                    }
                    .pickerStyle(.segmented)
                    .tint(.gray)
                }

                Section("Tresor") {
                    if let drive = model.drive, let vault = model.vault {
                        let files = drive.allFiles()
                        LabeledContent("Dateien", value: "\(files.count) · \(FileTypes.size(files.reduce(0) { $0 + $1.size }))")
                        LabeledContent("Notizen", value: "\(vault.index.notes.count)")
                        LabeledContent("Aufgaben", value: "\(vault.index.boards.reduce(0) { $0 + $1.columns.reduce(0) { $0 + $1.cards.count } })")
                        LabeledContent("Speicherort") {
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([vault.root]) }
                        }
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        XLogo(size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("xTool \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 13, weight: .medium))
                            Text("AES-256 · Argon2id · ohne Netzwerkzugriff").font(.system(size: 11)).foregroundStyle(.secondary)
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
        panel.nameFieldStringValue = "xTool-Sicherung-\(Date().formatted(.iso8601.year().month().day())).xvault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.createBackup(to: url)
    }

    private func exportAll() {
        guard let drive = model.drive else { return }
        let ids = drive.children(of: nil).map(\.id)
        guard !ids.isEmpty else {
            model.showToast("Es gibt noch keine Dateien.")
            return
        }
        guard let folder = Panels.chooseExportFolder(count: ids.count) else { return }
        // one folder around everything, so nothing mixes with what is already there
        let target = folder.appendingPathComponent("xTool-Export \(Date().formatted(.iso8601.year().month().day()))")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            model.exportNodes(ids, to: target)
        } catch {
            model.alert = AlertInfo(title: "Export nicht möglich", message: error.localizedDescription)
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
        SheetLayout(title: "Master-Passwort ändern", width: 400) {
            VStack(alignment: .leading, spacing: 14) {
                PasswordField(title: "Aktuelles Passwort", text: $current, revealed: $revealCurrent)
                NewPasswordForm(password: $new, confirmation: $confirmation, previous: current, onSubmit: change)
                Text("Ältere Sicherungen öffnen sich weiter mit dem alten Passwort. Erstelle danach am besten eine neue.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(XColor.danger) }
            }
        } buttons: {
            if busy { ProgressView().controlSize(.small) }
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.xQuiet)
            Button("Ändern", action: change).keyboardShortcut(.defaultAction).buttonStyle(.xPrimary).disabled(!canChange)
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
                    model.showToast("Passwort geändert")
                    dismiss()
                } else {
                    error = "Das aktuelle Passwort ist nicht korrekt."
                }
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
