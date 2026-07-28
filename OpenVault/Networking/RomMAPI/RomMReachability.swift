import Foundation

/// Where the API client reports what it learned about the server.
///
/// Reachability is evidence gathered from traffic the app was making anyway
/// rather than a separate probe, so it stays correct without polling.
protocol RomMReachabilityRecording: Sendable {
    /// RomM answered. The status code does not matter: a refusal still proves
    /// the connection works.
    func recordServerAnswered()

    /// A request failed. Only genuine transport failures change the verdict;
    /// cancellations, decoding failures, and rejections are ignored.
    func recordFailure(_ error: any Error)
}

/// The app's shared view of whether RomM can be reached.
///
/// Every request funnels through here, so a single successful call from any
/// feature is enough to clear an offline state, and no feature has to guess at
/// connectivity from its own local failure.
final class RomMReachability: RomMReachabilityRecording, @unchecked Sendable {
    static let shared = RomMReachability()

    private let lock = NSLock()
    private var reachable = true
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    init() {}

    var isReachable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    func recordServerAnswered() {
        publish(true)
    }

    func recordFailure(_ error: any Error) {
        guard RomMAPIError.indicatesServerUnreachable(error) else {
            return
        }
        publish(false)
    }

    /// Emits the current value immediately, then every change until the
    /// returned stream is torn down.
    func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()

            lock.lock()
            observers[id] = { value in
                continuation.yield(value)
            }
            let current = reachable
            lock.unlock()

            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else {
                    return
                }
                lock.lock()
                observers[id] = nil
                lock.unlock()
            }
        }
    }

    private func publish(_ value: Bool) {
        lock.lock()
        guard reachable != value else {
            lock.unlock()
            return
        }
        reachable = value
        let observers = Array(self.observers.values)
        lock.unlock()

        OpenVaultLog.network.notice(
            "RomM is now \(value ? "reachable" : "unreachable", privacy: .public)"
        )
        for observe in observers {
            observe(value)
        }
    }
}
