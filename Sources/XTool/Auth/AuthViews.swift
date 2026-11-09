import SwiftUI
import UniformTypeIdentifiers
import XToolCore

/// The black screen around login and setup.
private struct LockScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            XColor.lockScreen.ignoresSafeArea()
            content()
        }
        .environment(\.colorScheme, .dark)
    }
}

/// First start: choose the master password, or bring back a backup.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirmation = ""
    @State private var understood = false
    @State private var busy = false
    @State private var error: String?
    @State private var restore = RestoreRequest()

    private var canCreate: Bool {
        !busy && understood && NewPasswordForm.isValid(password: password, confirmation: confirmation)
    }

    var body: some View {
        LockScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    XLogoMark(size: 96).frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Master-Passwort festlegen").font(.system(size: 20, weight: .semibold))
                        Text("Es verschlüsselt alles in xTool.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    NewPasswordForm(password: $password, confirmation: $confirmation, onSubmit: create)
                    Toggle(isOn: $understood) {
                        Text("Ich weiß: Ohne dieses Passwort sind meine Daten für immer verloren. Niemand kann es zurücksetzen.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(XColor.danger) }
                    Button(action: create) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Text("Tresor erstellen")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.xPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    Button("Aus einer Sicherung wiederherstellen …") { restore.choose() }
                        .buttonStyle(.xQuiet)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 360)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .modifier(RestorePrompt(request: $restore))
        .task {
            #if DEBUG
            await TestTour.showSetup(model)
            #endif
        }
    }

    private func create() {
        guard canCreate else { return }
        busy = true
        error = nil
        Task {
            do { try await model.createVault(password: password) } catch { self.error = "Der Tresor konnte nicht erstellt werden: \(error.localizedDescription)" }
            busy = false
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var revealed = false
    @State private var busy = false
    @State private var error: String?
    @State private var wait = 0
    @State private var failures = 0
    private let guardState = LoginGuard(vaultRoot: Vault.defaultRoot)

    var body: some View {
        LockScreen {
            VStack(spacing: 20) {
                XLogoMark(size: 150)
                HStack(spacing: 8) {
                    PasswordField(title: "Passwort", text: $password, revealed: $revealed, onSubmit: unlock)
                        .disabled(busy)
                    Button(action: unlock) {
                        Group {
                            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.right") }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.xPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || wait > 0 || password.isEmpty)
                    .help("Entsperren")
                }
                .frame(width: 320)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(wait > 0 || error != nil ? XColor.danger : Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 320, height: 34, alignment: .top)
            }
        }
        // counts down only while there is something to wait for: no timer running otherwise
        .task(id: failures) {
            wait = Int(ceil(guardState.remainingWait()))
            while wait > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                wait = Int(ceil(guardState.remainingWait()))
            }
        }
        .task {
            #if DEBUG
            await TestTour.unlockIfRequested(model)
            #endif
        }
    }

    private var statusText: String {
        if wait > 0 { return "Falsches Passwort. Nächster Versuch in \(wait) s." }
        return error ?? model.lockNotice ?? " "
    }

    private func unlock() {
        guard !busy, !password.isEmpty, guardState.remainingWait() <= 0 else { return }
        busy = true
        error = nil
        let pw = password
        Task {
            do {
                if try await model.unlock(password: pw) {
                    guardState.reset()
                } else {
                    guardState.registerFailure()
                    failures += 1
                    error = "Falsches Passwort."
                    password = ""
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: restoring a backup (from setup or settings)

struct RestoreRequest {
    var url: URL?
    var password = ""

    mutating func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xvault") ?? .data]
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        password = ""
        url = picked
    }
}

struct RestorePrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: RestoreRequest

    func body(content: Content) -> some View {
        content.alert("Passwort der Sicherung", isPresented: Binding(get: { request.url != nil }, set: { if !$0 { request.url = nil } })) {
            SecureField("Passwort", text: $request.password)
            Button("Wiederherstellen", role: .destructive) {
                if let url = request.url { model.restoreBackup(from: url, password: request.password) }
                request.url = nil
            }
            Button("Abbrechen", role: .cancel) { request.url = nil }
        } message: {
            Text(model.state == .setup
                 ? "Die Sicherung wird als dein Tresor eingespielt."
                 : "Dein aktueller Tresor wird ersetzt. Der bisherige Stand wird aufbewahrt.")
        }
    }
}
