import AppKit
import SwiftUI
import XToolCore

/// Password input with show/hide and a Caps Lock warning.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    /// Shown as plain text. Passed in so a suggestion can reveal itself.
    @Binding var revealed: Bool
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: revealed ? .monospaced : .default))
            .focused($focused)
            .onSubmit(onSubmit)

            if capsLock && focused {
                Image(systemName: "capslock.fill").font(.system(size: 11)).foregroundStyle(XColor.warning).help("Die Feststelltaste ist aktiv")
            }
            Button {
                revealed.toggle()
                focused = true
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(revealed ? "Passwort verbergen" : "Passwort anzeigen")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.small + 1, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: XRadius.small + 1, style: .continuous).strokeBorder(focused ? XColor.accent : XColor.line))
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                capsLock = event.modifierFlags.contains(.capsLock)
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Four segments and one sentence: how strong, and what to do about it.
struct StrengthMeter: View {
    let report: PasswordReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { i in
                    Capsule().fill(i <= report.score ? color : XColor.line).frame(height: 3)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(report.hint ?? (report.score > 0 ? " " : "Mindestens \(PasswordPolicy.minimumLength) Zeichen. Mehrere zufällige Wörter sind ideal."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(report.label).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            }
        }
        .animation(.easeOut(duration: 0.15), value: report.score)
    }

    private var color: Color {
        switch report.score {
        case 1: return XColor.danger
        case 2: return XColor.warning
        default: return XColor.accent
        }
    }
}

/// Choosing a new master password: entry, strength, suggestion, confirmation.
struct NewPasswordForm: View {
    @Binding var password: String
    @Binding var confirmation: String
    /// The current password, when changing it.
    var previous: String?
    var onSubmit: () -> Void = {}
    @State private var revealed = false
    @State private var revealedConfirmation = false

    static func isValid(password: String, confirmation: String, previous: String? = nil) -> Bool {
        PasswordPolicy.evaluate(password, previous: previous).isAcceptable && password == confirmation
    }

    private var report: PasswordReport { PasswordPolicy.evaluate(password, previous: previous) }
    private var mismatch: Bool { !confirmation.isEmpty && !password.hasPrefix(confirmation) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PasswordField(title: "Neues Passwort", text: $password, revealed: $revealed)
            StrengthMeter(report: report)
            Button {
                password = PasswordGenerator.passphrase()
                confirmation = ""
                revealed = true
            } label: {
                Label("Passwort vorschlagen", systemImage: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundStyle(XColor.accent)
            }
            .buttonStyle(.plain)
            .help("Erzeugt sechs zufällige Wörter: leicht zu merken, kaum zu erraten.")

            PasswordField(title: "Passwort wiederholen", text: $confirmation, revealed: $revealedConfirmation, onSubmit: onSubmit)
                .padding(.top, 6)
            if mismatch {
                Text("Die Eingabe stimmt noch nicht überein.").font(.system(size: 11)).foregroundStyle(XColor.danger)
            }
        }
    }
}
