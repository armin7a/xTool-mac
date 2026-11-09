import AppKit

/// Screen protection: xTool windows are left out of screenshots, screen recordings and screen sharing
/// (NSWindow.sharingType = .none). Applied to every window as it appears.
@MainActor
enum ScreenGuard {
    private(set) static var enabled = true
    private static var observer: NSObjectProtocol?

    static func install() {
        #if DEBUG
        // the CI screenshot tour needs visible windows; it switches the guard on at the end to check it
        if TestTour.enabled { enabled = false }
        #endif
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { apply(window) }
        }
        NSApp.windows.forEach(apply)
    }

    static func setEnabled(_ on: Bool) {
        enabled = on
        NSApp.windows.forEach(apply)
    }

    private static func apply(_ window: NSWindow) {
        if window.isRestorable { window.isRestorable = false } // macOS keeps no state of this window
        let wanted: NSWindow.SharingType = enabled ? .none : .readOnly
        if window.sharingType != wanted { window.sharingType = wanted }
    }
}
