import Foundation
import Network

/// Where RetroVault should look for a DSU server.
///
/// Every live slot is consumed automatically and keeps its player number, so
/// users do not need to choose a slot in advance.
struct DSUConfiguration: Equatable, Sendable {
    var host: String = DSUProtocol.defaultHost
    var port: UInt16 = DSUProtocol.defaultPort

    /// A configuration is only usable once a host survives trimming; the
    /// settings field is free text.
    var normalized: Self? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0 else {
            return nil
        }
        return Self(host: trimmedHost, port: port)
    }
}

enum DSUPreferences {
    static let isEnabledKey = "dsu.client.enabled.v1"
    static let hostKey = "dsu.client.host.v1"
    static let portKey = "dsu.client.port.v1"
    static let layoutKey = "dsu.client.layout.v1"
    /// Diagnostic only, and off unless set by hand:
    /// `defaults write org.kennethreitz.RetroVault dsu.client.latency.v1 -bool true`
    static let latencyLoggingKey = "dsu.client.latency.v1"

    static let enabledByDefault = false
    static let defaultLayout = ControllerFaceButtonLayout.standard

    /// A DSU packet carries no vendor identity, so the face-button layout its
    /// server is publishing cannot be detected the way an attached
    /// controller's can. It is a setting instead.
    static func layout(
        from defaults: UserDefaults = .standard
    ) -> ControllerFaceButtonLayout {
        defaults.string(forKey: layoutKey)
            .flatMap(ControllerFaceButtonLayout.init(rawValue:))
            ?? defaultLayout
    }

    /// The configuration the app should currently be connected with, or `nil`
    /// when DSU input is switched off.
    static func activeConfiguration(
        from defaults: UserDefaults = .standard
    ) -> DSUConfiguration? {
        guard defaults.bool(forKey: isEnabledKey) else {
            return nil
        }
        return configuration(from: defaults).normalized
    }

    static func configuration(from defaults: UserDefaults = .standard) -> DSUConfiguration {
        var configuration = DSUConfiguration()
        if let host = defaults.string(forKey: hostKey), !host.isEmpty {
            configuration.host = host
        }
        if let port = UInt16(exactly: defaults.integer(forKey: portKey)), port > 0 {
            configuration.port = port
        }
        return configuration
    }
}

struct RoutedDSUPad: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case network(remoteSlot: UInt8)
        case gameController
    }

    var state: DSUPadState
    var layout: ControllerFaceButtonLayout
    var source: Source
}

/// The read side of RetroVault's unified controller connection.
protocol DSUPadReading: AnyObject, Sendable {
    /// Live controller states in stable player order. Callers run on the
    /// emulator thread once per frame, so this must never block on I/O.
    func currentPads() -> [RoutedDSUPad]

    /// Routes Libretro's two motor amplitudes to the controller occupying a
    /// published player slot. Implementations return false when no output
    /// path exists for that slot.
    @discardableResult
    func setRumble(slot: UInt8, strong: UInt16, weak: UInt16) -> Bool
}

extension DSUPadReading {
    @discardableResult
    func setRumble(slot: UInt8, strong: UInt16, weak: UInt16) -> Bool {
        false
    }
}

/// Measures the gap between a DSU server sampling the controller and this
/// client storing the packet — the cost of going through a bridge rather than
/// reading the device directly.
///
/// The server stamps microseconds on `CLOCK_UPTIME_RAW`, which is the clock
/// `DispatchTime.uptimeNanoseconds` reads, so the two are comparable across
/// processes without any handshake. A server stamping anything else — most
/// stamp a process-relative monotonic clock — yields deltas outside any
/// plausible range; those are counted and reported as unmeasurable rather than
/// averaged into a number that would look like latency.
private struct DSULatencySampler {
    /// A packet apparently older than a second, or stamped in the future, is a
    /// clock mismatch rather than a slow hop.
    private static let plausible: ClosedRange<Int64> = 0...1_000_000
    private static let reportInterval: UInt64 = 2_000_000_000
    /// A stalled reporting window must not grow the buffer without bound.
    private static let sampleLimit = 4_096

    private var samples: [Int64] = []
    private var discarded = 0
    private var windowStart: UInt64 = 0

    /// Records one packet, returning a line to log once per reporting window.
    mutating func record(
        stampedMicroseconds: UInt64,
        arrivalNanoseconds: UInt64
    ) -> String? {
        if windowStart == 0 {
            windowStart = arrivalNanoseconds
        }

        if stampedMicroseconds > 0 {
            let delta =
                Int64(arrivalNanoseconds / 1_000) - Int64(clamping: stampedMicroseconds)
            if Self.plausible.contains(delta) {
                if samples.count < Self.sampleLimit {
                    samples.append(delta)
                }
            } else {
                discarded += 1
            }
        }

        guard arrivalNanoseconds &- windowStart >= Self.reportInterval else {
            return nil
        }
        defer {
            samples.removeAll(keepingCapacity: true)
            discarded = 0
            windowStart = arrivalNanoseconds
        }

        guard !samples.isEmpty else {
            guard discarded > 0 else {
                return nil
            }
            return """
                latency unmeasurable — \(discarded) packets carried a clock \
                this process cannot compare against
                """
        }

        let sorted = samples.sorted()
        return """
            hop over \(sorted.count) packets: \
            median \(Self.milliseconds(sorted, 0.5)), \
            p95 \(Self.milliseconds(sorted, 0.95)), \
            max \(Self.milliseconds(sorted, 1))
            """
    }

    private static func milliseconds(_ sorted: [Int64], _ fraction: Double) -> String {
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return String(format: "%.2f ms", Double(sorted[index]) / 1_000)
    }
}

/// A DSU ("cemuhook") client. It subscribes to a server over UDP and keeps the
/// latest packet per slot in a lock-guarded snapshot.
///
/// Receiving happens on a private queue; the emulator thread only ever takes an
/// uncontended lock and copies a value type, which keeps the DSU pad off the
/// frame's critical path.
final class DSUClient: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case connecting
        /// Connected, but the server has not sent pad data for the slot yet.
        case waiting
        case receiving(slots: [UInt8], hasMotion: Bool)
        case failed(String)

        var summary: String {
            switch self {
            case .idle:
                return "Not connected."
            case .connecting:
                return "Connecting…"
            case .waiting:
                return "Connected, waiting for a controller."
            case let .receiving(slots, hasMotion):
                let noun = slots.count == 1 ? "controller" : "controllers"
                let slotList = slots.map { String(Int($0) + 1) }.joined(separator: ", ")
                return hasMotion
                    ? "Receiving \(slots.count) \(noun) (slots \(slotList)), including motion."
                    : "Receiving \(slots.count) \(noun) (slots \(slotList))."
            case let .failed(message):
                return message
            }
        }
    }

    /// A pad is considered live only this long after its last packet, so a
    /// server that disappears releases the buttons it was holding down.
    private static let staleInterval: TimeInterval = 0.5
    /// Servers drop silent clients, so the subscription is renewed well inside
    /// the protocol's five-second inactivity window.
    private static let renewalInterval: TimeInterval = 1

    let configuration: DSUConfiguration

    private let clientID = UInt32.random(in: UInt32.min...UInt32.max)
    private let queue = DispatchQueue(
        label: "org.kennethreitz.RetroVault.dsu",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var connection: NWConnection?
    private var renewalTimer: DispatchSourceTimer?
    private var rumbleTimer: DispatchSourceTimer?
    private var activeRumble: [UInt8: (strong: UInt8, weak: UInt8)] = [:]
    private var pads: [UInt8: DSUPadState] = [:]
    private var padTimestamps: [UInt8: UInt64] = [:]
    private var storedStatus: Status = .idle
    private var isRunning = false
    private let isMeasuringLatency = UserDefaults.standard.bool(
        forKey: DSUPreferences.latencyLoggingKey
    )
    private var latency = DSULatencySampler()

    init(configuration: DSUConfiguration) {
        self.configuration = configuration
    }

    deinit {
        connection?.cancel()
        renewalTimer?.cancel()
        rumbleTimer?.cancel()
    }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }

        // A stale snapshot should read as "waiting" rather than claim a pad
        // that stopped reporting.
        if case .receiving = storedStatus, livePadsLocked().isEmpty {
            return .waiting
        }
        return storedStatus
    }

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        storedStatus = .connecting
        lock.unlock()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }

        lock.lock()
        self.connection = connection
        lock.unlock()

        RetroVaultLog.network.notice(
            "Connecting to DSU server \(self.configuration.host, privacy: .public):\(self.configuration.port, privacy: .public)"
        )
        connection.start(queue: queue)
    }

    func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let connection = self.connection
        let timer = renewalTimer
        let rumbleTimer = rumbleTimer
        let rumblingSlots = Array(activeRumble.keys)
        self.connection = nil
        renewalTimer = nil
        self.rumbleTimer = nil
        activeRumble.removeAll()
        pads.removeAll()
        padTimestamps.removeAll()
        storedStatus = .idle
        lock.unlock()

        timer?.cancel()
        rumbleTimer?.cancel()
        for slot in rumblingSlots {
            sendRumble(
                slot: slot,
                strong: 0,
                weak: 0,
                over: connection
            )
        }
        connection?.cancel()
    }

    func currentPads() -> [DSUPadState] {
        lock.lock()
        defer { lock.unlock() }
        return livePadsLocked()
    }

    /// Every slot that has reported recently, for the settings connection test.
    func liveSlots() -> [DSUPadState] {
        lock.lock()
        defer { lock.unlock() }
        return livePadsLocked()
    }

    /// Sends both Libretro motors to an upstream DSU server.
    ///
    /// The unofficial extension uses byte intensities and expects an active
    /// effect to be refreshed. A small timer owns that keepalive so cores only
    /// have to report changes, which is what the Libretro API promises.
    @discardableResult
    func setRumble(slot: UInt8, strong: UInt16, weak: UInt16) -> Bool {
        let byteStrong = UInt8(strong >> 8)
        let byteWeak = UInt8(weak >> 8)

        lock.lock()
        guard isRunning, let connection else {
            lock.unlock()
            return false
        }
        if byteStrong == 0, byteWeak == 0 {
            activeRumble.removeValue(forKey: slot)
        } else {
            activeRumble[slot] = (byteStrong, byteWeak)
        }
        let needsTimer = !activeRumble.isEmpty && rumbleTimer == nil
        let shouldStopTimer = activeRumble.isEmpty
        let timer = shouldStopTimer ? rumbleTimer : nil
        if shouldStopTimer {
            rumbleTimer = nil
        }
        lock.unlock()

        sendRumble(
            slot: slot,
            strong: byteStrong,
            weak: byteWeak,
            over: connection
        )
        timer?.cancel()
        if needsTimer {
            startRumbleTimer()
        }
        return true
    }

    // MARK: - Connection

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendSubscription()
            startRenewalTimer()
            receiveNext()
        case let .failed(error):
            report(.failed("DSU connection failed: \(error.localizedDescription)"))
        case let .waiting(error):
            // UDP "waiting" is usually a sandbox or local-network denial; it
            // will not resolve on its own, so surface it rather than hang.
            report(.failed("DSU connection unavailable: \(error.localizedDescription)"))
        case .cancelled:
            report(.idle)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func startRenewalTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.renewalInterval,
            repeating: Self.renewalInterval
        )
        timer.setEventHandler { [weak self] in
            self?.sendSubscription()
        }

        lock.lock()
        renewalTimer?.cancel()
        renewalTimer = timer
        lock.unlock()

        timer.resume()
    }

    private func startRumbleTimer() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.rumbleTimer == nil, !self.activeRumble.isEmpty else {
                self.lock.unlock()
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.rumbleTimer = timer
            self.lock.unlock()

            timer.schedule(
                deadline: .now() + .milliseconds(100),
                repeating: .milliseconds(100),
                leeway: .milliseconds(10)
            )
            timer.setEventHandler { [weak self] in
                self?.refreshRumble()
            }
            timer.activate()
        }
    }

    private func refreshRumble() {
        lock.lock()
        let connection = self.connection
        let effects = activeRumble
        lock.unlock()

        for (slot, effect) in effects {
            sendRumble(
                slot: slot,
                strong: effect.strong,
                weak: effect.weak,
                over: connection
            )
        }
    }

    private func sendRumble(
        slot: UInt8,
        strong: UInt8,
        weak: UInt8,
        over connection: NWConnection?
    ) {
        guard let connection else { return }
        connection.send(
            content: DSUProtocol.rumbleRequest(
                slot: slot,
                motor: 0,
                intensity: strong,
                clientID: clientID
            ),
            completion: .idempotent
        )
        connection.send(
            content: DSUProtocol.rumbleRequest(
                slot: slot,
                motor: 1,
                intensity: weak,
                clientID: clientID
            ),
            completion: .idempotent
        )
    }

    private func sendSubscription() {
        lock.lock()
        let connection = self.connection
        lock.unlock()

        guard let connection else {
            return
        }
        connection.send(
            content: DSUProtocol.controllerInfoRequest(clientID: clientID),
            completion: .idempotent
        )
        connection.send(
            content: DSUProtocol.padDataRequest(clientID: clientID),
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.report(
                        .failed("DSU request failed: \(error.localizedDescription)")
                    )
                }
            }
        )
    }

    private func receiveNext() {
        lock.lock()
        let connection = self.connection
        lock.unlock()

        guard let connection else {
            return
        }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            guard error == nil else {
                self.report(
                    .failed("DSU receive failed: \(error!.localizedDescription)")
                )
                return
            }
            self.receiveNext()
        }
    }

    private func ingest(_ datagram: Data) {
        let message: DSUMessage
        do {
            message = try DSUProtocol.decode(datagram)
        } catch {
            // Malformed or foreign datagrams are expected on a shared port and
            // are not worth interrupting play over.
            RetroVaultLog.network.debug(
                "Discarded DSU datagram: \(String(describing: error), privacy: .public)"
            )
            return
        }

        switch message {
        case .protocolVersion, .controllerInfo, .motorInfo:
            break
        case let .controllerData(pad):
            store(pad)
        }
    }

    private func store(_ pad: DSUPadState) {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let arrival = DispatchTime.now().uptimeNanoseconds
        pads[pad.slot] = pad
        padTimestamps[pad.slot] = arrival
        var announcement: String?
        var latencyReport: String?
        if isMeasuringLatency {
            latencyReport = latency.record(
                stampedMicroseconds: pad.motion.timestamp,
                arrivalNanoseconds: arrival
            )
        }
        let livePads = livePadsLocked()
        let status: Status = livePads.isEmpty
            ? .waiting
            : .receiving(
                slots: livePads.map(\.slot),
                hasMotion: livePads.contains(where: \.reportsMotion)
            )
        if storedStatus != status {
            announcement = status.summary
        }
        storedStatus = status
        lock.unlock()

        if let announcement {
            RetroVaultLog.network.notice("DSU: \(announcement, privacy: .public)")
        }
        if let latencyReport {
            RetroVaultLog.network.notice("DSU: \(latencyReport, privacy: .public)")
        }
    }

    private func report(_ status: Status) {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let changed = storedStatus != status
        storedStatus = status
        lock.unlock()

        guard changed else {
            return
        }
        if case let .failed(message) = status {
            RetroVaultLog.network.error("\(message, privacy: .public)")
        }
    }

    private func livePadsLocked() -> [DSUPadState] {
        pads.values
            .filter { $0.isConnected && isFresh(slot: $0.slot) }
            .sorted { $0.slot < $1.slot }
    }

    /// Requires `lock` to be held.
    private func isFresh(slot: UInt8) -> Bool {
        guard let timestamp = padTimestamps[slot] else {
            return false
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- timestamp
        return TimeInterval(elapsed) / 1_000_000_000 < Self.staleInterval
    }
}
