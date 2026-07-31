import Foundation

/// The process-wide DSU connection.
///
/// Big Picture, the library grid, and the player all read the same pad, so the
/// socket is opened once for the app rather than per game, and is reconfigured
/// whenever the DSU settings change.
final class DSUConnection: DSUPadReading, @unchecked Sendable {
    static let shared = DSUConnection()

    private let lock = NSLock()
    private var activeClient: DSUClient?
    private var storedLayout = DSUPreferences.defaultLayout

    private init() {}

    /// Kept apart from `DSUConfiguration` so changing it re-reads the pad's
    /// buttons without tearing down a working socket.
    var padLayout: ControllerFaceButtonLayout {
        lock.lock()
        defer { lock.unlock() }
        return storedLayout
    }

    func apply(layout: ControllerFaceButtonLayout) {
        lock.lock()
        let changed = storedLayout != layout
        storedLayout = layout
        lock.unlock()

        guard changed else {
            return
        }
        RetroVaultLog.network.notice(
            "DSU face-button layout set to \(layout.rawValue, privacy: .public)"
        )
    }

    var client: DSUClient? {
        lock.lock()
        defer { lock.unlock() }
        return activeClient
    }

    var status: DSUClient.Status {
        client?.status ?? .idle
    }

    /// Opens, reconfigures, or closes the connection. Passing `nil` disconnects.
    func apply(_ configuration: DSUConfiguration?) {
        lock.lock()
        let previous = activeClient
        guard previous?.configuration != configuration else {
            lock.unlock()
            return
        }
        let next = configuration.map(DSUClient.init(configuration:))
        activeClient = next
        lock.unlock()

        previous?.stop()
        next?.start()
    }

    func currentPad() -> DSUPadState? {
        client?.currentPad()
    }
}
