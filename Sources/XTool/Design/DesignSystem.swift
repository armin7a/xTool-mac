import AppKit
import SwiftUI

/// The whole look of the app in one place: colours from the logo, one accent, few surfaces.
enum XColor {
    /// The logo's green. Darker in light mode, where the neon tone would be unreadable.
    static let accent = dynamic(light: 0x2F8A10, dark: 0x8CF04A)
    /// Text on the accent colour.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0A0F05)
    /// Window background.
    static let canvas = dynamic(light: 0xF8F8F6, dark: 0x0E0E0F)
    /// Cards, fields.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x19191B)
    static let line = Color.primary.opacity(0.09)
    static let hover = Color.primary.opacity(0.06)
    static let danger = dynamic(light: 0xC62B2B, dark: 0xFF6B60)
    static let warning = dynamic(light: 0xB86E00, dark: 0xFFB340)
    /// The screen behind the logo when locked: the black of the logo picture itself.
    static let lockScreen = Color(red: 0.016, green: 0.019, blue: 0.018)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum XRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
}

enum Theme {
    static func apply(_ setting: String) {
        switch setting {
        case "Light": NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Login and setup are always dark: the logo is made for black.
    static func applyLockScreen() { apply("Dark") }
}

// MARK: logo

enum Brand {
    static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        #if DEBUG
        // running the bare binary during development
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Logo.png")
        return NSImage(contentsOf: source)
        #else
        return nil
        #endif
    }()
}

/// The logo as a tile: works on any background.
struct XLogo: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let logo = Brand.logo {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().padding(size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .background(XColor.lockScreen)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// The logo without a tile, melting into the lock screen's black.
struct XLogoMark: View {
    var size: CGFloat = 120

    var body: some View {
        if let logo = Brand.logo {
            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                // only the outermost edge of the picture fades, so no square shows against the lock screen
                .mask(Rectangle().padding(size * 0.05).blur(radius: size * 0.03))
        }
    }
}

// MARK: buttons

/// The one prominent action of a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(XColor.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(XColor.accent, in: RoundedRectangle(cornerRadius: XRadius.small + 1, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
                .contentShape(Rectangle())
        }
    }
}

/// Everything else: no border until the pointer is on it.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(hovering || configuration.isPressed ? XColor.hover : .clear, in: RoundedRectangle(cornerRadius: XRadius.small, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var xPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var xQuiet: QuietButtonStyle { QuietButtonStyle() }
}

/// A symbol-only button with a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(hovering ? XColor.hover : .clear, in: RoundedRectangle(cornerRadius: XRadius.small, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: building blocks

/// Heading of a page.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// What a page shows when it has nothing to show.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium)).padding(.top, 4)
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            action().padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A sheet with title, content and a bottom row of buttons.
struct SheetLayout<Content: View, Buttons: View>: View {
    let title: String
    var width: CGFloat = 420
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
            HStack(spacing: 8) {
                Spacer()
                buttons()
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

/// Native confirmation: for choices that shouldn't be made by a stray keypress.
enum Panels {
    /// Files and folders to bring into the vault.
    @MainActor static func chooseFilesToImport() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Die Dateien werden verschlüsselt in xTool kopiert. Die Originale bleiben, wo sie sind."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Where exported files go.
    @MainActor static func chooseExportFolder(count: Int) -> URL? {
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Unverschlüsselt exportieren?"
        warning.informativeText = "Exportierte Dateien sind außerhalb von xTool nicht mehr geschützt. Jedes Programm und jeder, der Zugriff auf diesen Mac hat, kann sie lesen. Lösche sie, sobald du sie nicht mehr brauchst."
        warning.addButton(withTitle: "Weiter")
        warning.addButton(withTitle: "Abbrechen")
        guard warning.runModal() == .alertFirstButtonReturn else { return nil }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Hier speichern"
        panel.message = count == 1
            ? "Das Element wird entschlüsselt und liegt dort unverschlüsselt. In xTool bleibt es erhalten."
            : "\(count) Elemente werden entschlüsselt und liegen dort unverschlüsselt. In xTool bleiben sie erhalten."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
