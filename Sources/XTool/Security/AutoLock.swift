import AppKit

/// Locks after inactivity, when the screen locks, the MacBook sleeps (lid closed) or the user switches.
@MainActor
final class AutoLock {
    var onLock: (@MainActor () -> Void)?
    var minutes: @MainActor () -> Int = { 5 }
    /// True while a long job runs: only inactivity is ignored then, sleep and screen lock still lock.
    var isBusy: @MainActor () -> Bool = { false }
    private var lastInput = Date()
    private var timer: Timer?
    private var monitor: Any?

    func start() {
        guard timer == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .magnify]) { [weak self] event in
            self?.lastInput = Date()
            return event
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isBusy() { self.lastInput = Date(); return }
                let m = self.minutes()
                if m > 0, Date().timeIntervalSince(self.lastInput) > Double(m) * 60 { self.onLock?() }
            }
        }
        timer.tolerance = 5 // lets the MacBook bundle wake-ups and save battery
        self.timer = timer
        let lockNow: (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.onLock?() } }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow)
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lockNow)
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lockNow)
    }

    func touch() { lastInput = Date() }
}
