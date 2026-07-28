import Foundation

/// Keeps the display awake while a game is on screen.
///
/// macOS dims the display and then sleeps it after a stretch without input,
/// and on battery it dims sooner. A controller in hand is not input as far as
/// that timer is concerned — only the keyboard, trackpad, and mouse are — so a
/// game being played with a gamepad goes dark mid-session unless it says
/// otherwise.
///
/// This does not touch the brightness the user chose, nor the ambient light
/// sensor. It suppresses only the idle dim-and-sleep sequence, and only while
/// something is actually running.
final class DisplaySleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    init() {}

    deinit {
        end()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    /// Begins holding the display awake. Repeated calls keep the single
    /// existing assertion rather than stacking them.
    func begin(reason: String) {
        lock.lock()
        guard token == nil else {
            lock.unlock()
            return
        }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: reason
        )
        lock.unlock()

        OpenVaultLog.libretro.info(
            "Holding the display awake: \(reason, privacy: .public)"
        )
    }

    /// Releases the assertion. Safe to call when nothing is held, so every
    /// path out of gameplay can call it unconditionally.
    func end() {
        lock.lock()
        guard let token else {
            lock.unlock()
            return
        }
        self.token = nil
        lock.unlock()

        ProcessInfo.processInfo.endActivity(token)
    }
}
