import AppKit
import SwiftUI

/// Settings for the whole process, applied once at launch.
enum ProcessHardening {
    static func apply() {
        // no memory dump on a crash: it could contain keys and open documents
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false,     // macOS doesn't keep the state of open windows
            "NSDisabledDictationMenuItem": true,   // no dictation in the Edit menu
        ])
    }
}

/// Keeps Apple's Writing Tools away from every text field.
struct NoWritingTools: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.writingToolsBehavior(.disabled)
        } else {
            content
        }
    }
}

/// Removes what xTool copied once the vault locks, and in any case two minutes after the copy, like a
/// password manager. Whatever other apps put on the clipboard stays: a change made while xTool was in front is ours.
@MainActor
final class ClipboardGuard {
    static let shared = ClipboardGuard()
    private var baseline = NSPasteboard.general.changeCount
    private var lastOwnChange: Int?
    private var observers: [NSObjectProtocol] = []
    private var expiry: Task<Void, Never>?
    static let lifetime: UInt64 = 120

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardGuard.shared.baseline = NSPasteboard.general.changeCount }
        })
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardGuard.shared.noteOwnChange() }
        })
    }

    private func noteOwnChange() {
        let current = NSPasteboard.general.changeCount
        if current != baseline, lastOwnChange != current {
            lastOwnChange = current
            scheduleExpiry()
        }
    }

    /// Called by the editors, which know for sure that a copy came from xTool.
    func noteCopied() {
        lastOwnChange = NSPasteboard.general.changeCount
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.lifetime * 1_000_000_000)
            guard !Task.isCancelled else { return }
            ClipboardGuard.shared.clearIfOurs()
        }
    }

    func clearIfOurs() {
        if NSApp.isActive { noteOwnChange() }
        if lastOwnChange == NSPasteboard.general.changeCount {
            NSPasteboard.general.clearContents()
        }
        baseline = NSPasteboard.general.changeCount
        lastOwnChange = nil
        expiry?.cancel()
        expiry = nil
    }
}
