import Foundation

/// Slows down password guessing: 1, 2, 4 … 30 s after failed attempts. Survives restarts.
public final class LoginGuard {
    private struct State: Codable {
        var Failures = 0
        var LastFailureUtc = Date.distantPast
    }

    private let url: URL
    private var state: State

    public init(vaultRoot: URL) {
        url = vaultRoot.appendingPathComponent("attempts-mac.json")
        state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public var failures: Int { state.Failures }

    public var currentDelay: TimeInterval { state.Failures == 0 ? 0 : min(30, pow(2, Double(state.Failures - 1))) }

    public func remainingWait(now: Date = Date()) -> TimeInterval {
        // capped, so a clock that was set back can't lock anyone out for long
        min(currentDelay, max(0, state.LastFailureUtc.addingTimeInterval(currentDelay).timeIntervalSince(now)))
    }

    public func registerFailure(now: Date = Date()) {
        state.Failures += 1
        state.LastFailureUtc = now
        save()
    }

    public func reset() {
        guard state.Failures > 0 else { return }
        state = State()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
