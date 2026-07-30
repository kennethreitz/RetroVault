@preconcurrency import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
@preconcurrency import GameController
import Observation
import OpenGL
import OpenGL.GL3
import OSLog

@_silgen_name("openvault_libretro_log_callback_pointer")
private func openVaultLibretroLogCallbackPointer() -> UnsafeMutableRawPointer

enum LibretroPlayerOrigin: String, Codable, Hashable, Sendable {
    case bigPicture
}

struct LibretroRunRequest: Codable, Hashable, Sendable {
    let title: String
    let coreID: String
    let contentURL: URL?
    let systemName: String?
    let systemDirectory: URL?
    let saveSync: CartridgeSaveSyncConfiguration?
    let playerOrigin: LibretroPlayerOrigin?
    let skipsQuickStateRestore: Bool?

    init(
        title: String,
        coreID: String,
        contentURL: URL?,
        systemName: String? = nil,
        systemDirectory: URL? = nil,
        saveSync: CartridgeSaveSyncConfiguration? = nil,
        playerOrigin: LibretroPlayerOrigin? = nil,
        skipsQuickStateRestore: Bool? = nil
    ) {
        self.title = title
        self.coreID = coreID
        self.contentURL = contentURL
        self.systemName = systemName
        self.systemDirectory = systemDirectory
        self.saveSync = saveSync
        self.playerOrigin = playerOrigin
        self.skipsQuickStateRestore = skipsQuickStateRestore
    }

    var restoresQuickStateOnLaunch: Bool {
        skipsQuickStateRestore != true
    }

    var allowsRewind: Bool {
        LibretroRewindPolicy.isEnabled(forCoreID: coreID)
    }

    func startingFresh() -> Self {
        Self(
            title: title,
            coreID: coreID,
            contentURL: contentURL,
            systemName: systemName,
            systemDirectory: systemDirectory,
            saveSync: saveSync,
            playerOrigin: playerOrigin,
            skipsQuickStateRestore: true
        )
    }

    func launched(from origin: LibretroPlayerOrigin) -> Self {
        Self(
            title: title,
            coreID: coreID,
            contentURL: contentURL,
            systemName: systemName,
            systemDirectory: systemDirectory,
            saveSync: saveSync,
            playerOrigin: origin,
            skipsQuickStateRestore: skipsQuickStateRestore
        )
    }

    static let pipelineTest = Self(
        title: "2048",
        coreID: "libretro-2048",
        contentURL: nil
    )
}

enum LibretroQuickStateRestorePolicy {
    static func shouldRestore(
        requestAllowsRestore: Bool,
        remoteSaveUpdatedAt: Date?,
        quickStateUpdatedAt: Date?
    ) -> Bool {
        guard requestAllowsRestore else {
            return false
        }
        guard
            let remoteSaveUpdatedAt,
            let quickStateUpdatedAt
        else {
            return true
        }
        return remoteSaveUpdatedAt <= quickStateUpdatedAt
    }
}

enum LibretroQuickStateCompatibility {
    static let fingerprintFileName = "Quick.state.core"

    static func requiresCoreFingerprint(coreID: String) -> Bool {
        coreID.caseInsensitiveCompare("libretro-fake08") == .orderedSame
    }

    static func coreFingerprint(binaryURL: URL) throws -> String {
        let data = try Data(contentsOf: binaryURL, options: .mappedIfSafe)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isCompatible(
        coreID: String,
        expectedFingerprint: String?,
        storedFingerprint: String?
    ) -> Bool {
        guard requiresCoreFingerprint(coreID: coreID) else {
            return true
        }
        guard
            let expectedFingerprint,
            let storedFingerprint
        else {
            return false
        }
        return expectedFingerprint == storedFingerprint
    }
}

enum LibretroWiiControllerProfile: String, CaseIterable, Identifiable, Sendable {
    case classicControllerPro = "classic-controller-pro"
    case sidewaysWiiRemote = "sideways-wii-remote"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicControllerPro:
            "Classic Controller Pro"
        case .sidewaysWiiRemote:
            "Wii Remote (Sideways)"
        }
    }
}

enum LibretroWiiControllerPreferences {
    static let profileKey = "libretro.wii.controller-profile.v1"
    static let defaultProfile = LibretroWiiControllerProfile.classicControllerPro

    static func profile(
        from defaults: UserDefaults = .standard
    ) -> LibretroWiiControllerProfile {
        guard
            let rawValue = defaults.string(forKey: profileKey),
            let profile = LibretroWiiControllerProfile(rawValue: rawValue)
        else {
            return defaultProfile
        }
        return profile
    }
}

enum LibretroDigitalInputPreferences {
    static let mapsLeftAnalogToDPadKey =
        "libretro.input.left-analog-to-dpad.v1"
    static let mapsLeftAnalogToDPadByDefault = true

    static func mapsLeftAnalogToDPad(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: mapsLeftAnalogToDPadKey) as? Bool
            ?? mapsLeftAnalogToDPadByDefault
    }
}

enum LibretroControllerDevice {
    static let joypad: UInt32 = 1
    /// Dolphin's sideways Wii Remote libretro device subtype.
    static let sidewaysWiiRemote: UInt32 = (2 << 8) | joypad
    /// Dolphin's WiiMote + Classic Controller Pro libretro device subtype.
    static let wiiClassicControllerPro: UInt32 = (5 << 8) | joypad

    static func primaryDevice(
        coreID: String,
        systemName: String?,
        wiiProfile: LibretroWiiControllerProfile =
            LibretroWiiControllerPreferences.profile()
    ) -> UInt32 {
        guard
            coreID.caseInsensitiveCompare("libretro-dolphin") == .orderedSame,
            let systemName,
            ["wii", "nintendo wii"].contains(
                systemName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        else {
            return joypad
        }
        switch wiiProfile {
        case .classicControllerPro:
            return wiiClassicControllerPro
        case .sidewaysWiiRemote:
            return sidewaysWiiRemote
        }
    }
}

enum LibretroAnalogToDPadPolicy {
    private static let digitalOnlyCoreIDs: Set<String> = [
        "libretro-arduous",
        "libretro-beetle-ngp",
        "libretro-beetle-vb",
        "libretro-beetle-wswan",
        "libretro-bsnes-mercury-balanced",
        "libretro-fake08",
        "libretro-gambatte",
        "libretro-gearcoleco",
        "libretro-beetle-pce",
        "libretro-gearsystem",
        "libretro-genesis-plus-gx",
        "libretro-melonds",
        "libretro-mgba",
        "libretro-nestopia",
        "libretro-picodrive",
        "libretro-pokemini",
        "libretro-prosystem",
        "libretro-stella2014",
    ]

    static func applies(
        coreID: String,
        controllerDevice: UInt32,
        preferenceEnabled: Bool =
            LibretroDigitalInputPreferences.mapsLeftAnalogToDPad()
    ) -> Bool {
        guard preferenceEnabled else {
            return false
        }
        if controllerDevice == LibretroControllerDevice.sidewaysWiiRemote {
            return true
        }
        return digitalOnlyCoreIDs.contains(coreID.lowercased())
    }
}

enum LibretroInputPortRouting {
    static let controllerPortCount = 2

    static func localPorts(
        hasDSU: Bool,
        controllerCount: Int
    ) -> [Int] {
        let firstPort = hasDSU ? 1 : 0
        guard
            controllerCount > 0,
            firstPort < controllerPortCount
        else {
            return []
        }
        let count = min(
            controllerCount,
            controllerPortCount - firstPort
        )
        return Array(firstPort..<(firstPort + count))
    }
}

/// The stable directory key shared by the runtime and library resume scanner.
enum LibretroContentIdentity {
    static func key(for contentURL: URL?) -> String {
        let identity =
            contentURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            ?? "content-free"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum LibretroRewindPolicy {
    static func isEnabled(forCoreID coreID: String) -> Bool {
        let normalizedCoreID = coreID.lowercased()
        return !normalizedCoreID.contains("n64")
            && !normalizedCoreID.contains("mupen64")
    }
}

struct LibretroRewindCadence: Sendable {
    static let targetHistoryDuration = 8.0
    /// The shortest history worth keeping rewind on for.
    ///
    /// A core whose states are too large for `targetHistoryDuration` used to
    /// lose rewind outright. Trading history length for keeping the feature is
    /// the better deal: the PlayStation's roughly 3.5 MB states cannot hold
    /// eight seconds inside the budget, but they hold about three, which still
    /// covers the mistake the button gets pressed for. Below this the window
    /// is too short to aim at and rewind stays off.
    static let minimumHistoryDuration = 2.5
    static let minimumSnapshotsPerSecond = 12.0
    static let maximumSnapshotsPerSecond = 60.0
    static let maximumEntryCount = 3_600

    let framesPerSecond: Double
    let byteLimit: Int

    var initialSnapshotInterval: TimeInterval {
        1 / maximumSnapshotRate
    }

    /// The longest history the budget affords at the slowest useful capture
    /// rate, capped at what the runtime actually wants.
    ///
    /// Serialization runs on the emulation thread inside the frame budget, so
    /// the capture rate is never allowed below
    /// `minimumSnapshotsPerSecond`; what gives instead, for a core with large
    /// states, is how far back the history reaches.
    func sustainableHistoryDuration(
        forStateByteCount stateByteCount: Int
    ) -> TimeInterval {
        guard stateByteCount > 0 else {
            return Self.targetHistoryDuration
        }
        let affordable =
            Double(byteLimit)
            / Double(stateByteCount)
            / Self.minimumSnapshotsPerSecond
        return min(affordable, Self.targetHistoryDuration)
    }

    /// Whether the budget affords a history long enough to be worth keeping.
    func canSustainRewind(forStateByteCount stateByteCount: Int) -> Bool {
        guard stateByteCount > 0 else {
            return true
        }
        return sustainableHistoryDuration(forStateByteCount: stateByteCount)
            >= Self.minimumHistoryDuration
    }

    func snapshotInterval(forStateByteCount stateByteCount: Int) -> TimeInterval {
        guard stateByteCount > 0 else {
            return initialSnapshotInterval
        }

        let snapshotRate = min(
            maximumSnapshotRate,
            max(
                Self.minimumSnapshotsPerSecond,
                memoryBoundRate(forStateByteCount: stateByteCount)
            )
        )
        return 1 / snapshotRate
    }

    /// The rate at which the affordable history fits the budget.
    ///
    /// For a core small enough to reach `targetHistoryDuration` this is the
    /// rate that fills the budget over those eight seconds, exactly as before.
    /// For a core held to a shorter history it works out to the minimum rate,
    /// which is what keeps the per-frame serialization cost bounded.
    private func memoryBoundRate(
        forStateByteCount stateByteCount: Int
    ) -> Double {
        Double(byteLimit)
            / Double(stateByteCount)
            / sustainableHistoryDuration(forStateByteCount: stateByteCount)
    }

    private var maximumSnapshotRate: Double {
        min(
            Self.maximumSnapshotsPerSecond,
            max(framesPerSecond, 1)
        )
    }
}

struct LibretroRewindCaptureSchedule: Sendable {
    let framesPerSecond: Double

    private(set) var framesUntilCapture = 0

    mutating func shouldCapture() -> Bool {
        guard framesUntilCapture > 0 else {
            return true
        }
        framesUntilCapture -= 1
        return false
    }

    mutating func didCapture(
        snapshotInterval: TimeInterval
    ) {
        let frameDuration = 1 / max(framesPerSecond, 1)
        let frameInterval = max(
            Int((snapshotInterval / frameDuration).rounded()),
            1
        )
        framesUntilCapture = frameInterval - 1
    }

    mutating func reset() {
        framesUntilCapture = 0
    }
}

struct LibretroVideoFrame: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
    /// The display shape the core asked for, or 0 when it never said and the
    /// buffer's own proportions should be used.
    var aspectRatio: Float = 0
}

struct LibretroVideoSnapshot: Sendable {
    let frame: LibretroVideoFrame
    let revision: UInt64
}

struct LibretroRewindBuffer: Sendable {
    let byteLimit: Int
    let entryLimit: Int

    private var states: [Data] = []
    private(set) var byteCount = 0

    init(byteLimit: Int, entryLimit: Int) {
        self.byteLimit = max(byteLimit, 1)
        self.entryLimit = max(entryLimit, 1)
    }

    var count: Int {
        states.count
    }

    var isEmpty: Bool {
        states.isEmpty
    }

    @discardableResult
    mutating func append(_ state: Data) -> Bool {
        guard !state.isEmpty, state.count <= byteLimit else {
            removeAll()
            return false
        }

        states.append(state)
        byteCount += state.count

        while states.count > entryLimit || byteCount > byteLimit {
            byteCount -= states.removeFirst().count
        }
        return !states.isEmpty
    }

    mutating func popLast() -> Data? {
        guard let state = states.popLast() else {
            return nil
        }
        byteCount -= state.count
        return state
    }

    mutating func popLast(steps: Int) -> Data? {
        var state: Data?
        for _ in 0..<max(steps, 1) {
            guard let previousState = popLast() else {
                break
            }
            state = previousState
        }
        return state
    }

    mutating func removeAll() {
        states.removeAll(keepingCapacity: true)
        byteCount = 0
    }
}

struct LibretroControllerExitChord: Sendable {
    private var wasPressed = false

    mutating func update(
        startPressed: Bool,
        selectPressed: Bool
    ) -> Bool {
        let isPressed = startPressed && selectPressed
        defer {
            wasPressed = isPressed
        }
        return isPressed && !wasPressed
    }
}

final class LibretroVideoBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: LibretroVideoFrame?
    private var revision: UInt64 = 0

    func publish(_ frame: LibretroVideoFrame) {
        lock.lock()
        self.frame = frame
        revision &+= 1
        lock.unlock()
    }

    func snapshot() -> LibretroVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func versionedSnapshot() -> LibretroVideoSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let frame else {
            return nil
        }
        return LibretroVideoSnapshot(frame: frame, revision: revision)
    }
}

enum LibretroPlayerPreferences {
    static let opensInFullScreenKey =
        "libretro.player.opens-in-full-screen.v1"
    static let opensInFullScreenByDefault = false
}

enum LibretroTransportPreferences {
    static let enablesFastForwardKey =
        "libretro.transport.fast-forward-r3.v1"
    static let enablesRewindKey =
        "libretro.transport.rewind-l3.v1"
    static let enabledByDefault = true
}

struct LibretroTransportControls: Equatable, Sendable {
    var isRewinding = false
    var isFastForwarding = false

    static func controller(
        leftThumbstickButtonPressed: Bool,
        rightThumbstickButtonPressed: Bool,
        enablesRewind: Bool = true,
        enablesFastForward: Bool = true
    ) -> Self {
        Self(
            isRewinding:
                enablesRewind && leftThumbstickButtonPressed,
            isFastForwarding:
                enablesFastForward
                && rightThumbstickButtonPressed
                && !(enablesRewind && leftThumbstickButtonPressed)
        )
    }
}

final class LibretroInputState: @unchecked Sendable {
    struct KeyEvent: Equatable, Sendable {
        let key: UInt32
        let pressed: Bool
        let modifiers: UInt16
    }

    private struct ControllerPortState {
        var controllerButtons: UInt16 = 0
        var polledButtons: UInt16 = 0
        var leftAnalogX: Int16 = 0
        var leftAnalogY: Int16 = 0
        var rightAnalogX: Int16 = 0
        var rightAnalogY: Int16 = 0
    }

    private struct ResolvedPad {
        var buttons: UInt16
        var isSelectPressed: Bool
        var isStartPressed: Bool
        var isLeftStickPressed: Bool
        var isRightStickPressed: Bool
        var leftAnalogX: Int16
        var leftAnalogY: Int16
        var rightAnalogX: Int16
        var rightAnalogY: Int16
    }

    private let lock = NSLock()
    private var keyboardButtons: UInt16 = 0
    private var pendingKeyboardPresses: UInt16 = 0
    private var keyboardEnabled = false
    private var pointerRead = false
    private var pressedKeys: Set<UInt32> = []
    private var keyModifiers: UInt16 = 0
    private var pendingKeyEvents: [KeyEvent] = []
    private var controllerPorts = Array(
        repeating: ControllerPortState(),
        count: LibretroInputPortRouting.controllerPortCount
    )
    private var pointerX: Int16 = 0
    private var pointerY: Int16 = 0
    private var pointerPressed = false
    private var pointerInside = false
    private var transportControls = LibretroTransportControls()
    private var enablesRewind = true
    private var enablesFastForward = true
    private var exitChords = Array(
        repeating: LibretroControllerExitChord(),
        count: LibretroInputPortRouting.controllerPortCount
    )
    private var exitRequested = false
    private var assignedLocalControllers = Array<GCController?>(
        repeating: nil,
        count: LibretroInputPortRouting.controllerPortCount
    )
    private var padSource: (any DSUPadReading)?
    private var touchCalibration = DSUTouchCalibration()
    private var dsuPointer: LibretroDSUInput.Pointer?
    private var sensors = LibretroSensorValues()
    private var readsAccelerometer = false
    private var readsGyroscope = false
    private var mapsLeftAnalogToDPad = false

    /// Attaches an optional network pad, currently a DSU ("cemuhook") server,
    /// whose state is merged with the locally attached controller.
    func setPadSource(_ source: (any DSUPadReading)?) {
        lock.lock()
        padSource = source
        if source == nil {
            dsuPointer = nil
            sensors = LibretroSensorValues()
            touchCalibration = DSUTouchCalibration()
        }
        lock.unlock()
    }

    func setMapsLeftAnalogToDPad(_ maps: Bool) {
        lock.lock()
        mapsLeftAnalogToDPad = maps
        lock.unlock()
    }

    func setKeyboardButton(_ button: LibretroButton, pressed: Bool) {
        lock.lock()
        if pressed {
            keyboardButtons |= button.mask
            pendingKeyboardPresses |= button.mask
        } else {
            keyboardButtons &= ~button.mask
        }
        lock.unlock()
    }

    /// Whether the running core asked for a keyboard.
    ///
    /// A core that did takes every key as a key, and the RetroPad shortcuts
    /// the other cores get from the keyboard are switched off: in DOS a game
    /// reading the arrow keys and Return wants those keys, not a d-pad and
    /// Start synthesised from them.
    var readsKeyboard: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keyboardEnabled
    }

    /// Whether the running core has actually read the pointer.
    ///
    /// Taken from the core's own behaviour rather than from what the manifest
    /// says it supports, because this decides whether the mouse cursor is
    /// worth showing, and only a core that reads the pointer can put it to
    /// use. A core that never asks leaves this false and gets the cursor kept
    /// out of the way.
    var readsPointer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pointerRead
    }

    func setKeyboardEnabled(_ enabled: Bool) {
        lock.lock()
        keyboardEnabled = enabled
        if !enabled {
            pressedKeys.removeAll()
        } else {
            // The RetroPad shortcuts stop applying, so drop anything they
            // had latched rather than leave a button stuck down.
            keyboardButtons = 0
            pendingKeyboardPresses = 0
        }
        lock.unlock()
    }

    func setKey(_ retroKey: UInt32, pressed: Bool, modifiers: UInt16) {
        guard retroKey < UInt32(LibretroKeyboard.keyCount) else {
            return
        }
        lock.lock()
        if pressed {
            pressedKeys.insert(retroKey)
        } else {
            pressedKeys.remove(retroKey)
        }
        keyModifiers = modifiers
        pendingKeyEvents.append(
            KeyEvent(key: retroKey, pressed: pressed, modifiers: modifiers)
        )
        lock.unlock()
    }

    func keyValue(for retroKey: UInt32) -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        return pressedKeys.contains(retroKey) ? 1 : 0
    }

    /// Hands over the key presses seen since the last call, for delivery to a
    /// core's `retro_keyboard_callback`.
    func drainKeyEvents() -> [KeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = pendingKeyEvents
        pendingKeyEvents.removeAll(keepingCapacity: true)
        return events
    }

    func releaseKeyboard() {
        lock.lock()
        keyboardButtons = 0
        pendingKeyboardPresses = 0
        controllerPorts[0].polledButtons =
            controllerPorts[0].controllerButtons
        // Losing focus with keys held would otherwise leave the core holding
        // them forever, so report the release rather than just forgetting.
        for key in pressedKeys {
            pendingKeyEvents.append(
                KeyEvent(key: key, pressed: false, modifiers: 0)
            )
        }
        pressedKeys.removeAll()
        keyModifiers = 0
        lock.unlock()
    }

    func setPointer(
        x: Int16,
        y: Int16,
        pressed: Bool,
        inside: Bool
    ) {
        lock.lock()
        pointerX = x
        pointerY = y
        pointerPressed = pressed
        pointerInside = inside
        lock.unlock()
    }

    func pollController() {
        lock.lock()
        let padSource = self.padSource
        lock.unlock()
        // Read the network pad outside our own lock so a busy DSU server can
        // never stall the emulator thread behind it.
        let dsuState = padSource?.currentPad()
        let local = stableLocalControllers().compactMap {
            LibretroGamepadInput(controller: $0)
        }

        lock.lock()
        defer { lock.unlock() }

        let remote = dsuState.map {
            LibretroDSUInput.pad(
                from: $0,
                layout: padSource?.padLayout ?? .standard,
                calibration: &touchCalibration
            )
        }

        var routedPads = Array<ResolvedPad?>(
            repeating: nil,
            count: LibretroInputPortRouting.controllerPortCount
        )
        if let remote {
            // DSU is the explicitly configured network pad, so it owns player
            // one whenever it is live. The first ordinary macOS controller is
            // then player two rather than being merged into the same port.
            routedPads[0] = resolvedPad(remote)
        }
        // Without a live DSU pad, ordinary controllers naturally occupy
        // player one and player two. With DSU, the first local pad begins at
        // player two.
        let localPorts = LibretroInputPortRouting.localPorts(
            hasDSU: remote != nil,
            controllerCount: local.count
        )
        for (pad, port) in zip(local, localPorts) {
            routedPads[port] = resolvedPad(pad)
        }

        for port in 0..<LibretroInputPortRouting.controllerPortCount {
            var state = ControllerPortState()
            if var pad = routedPads[port] {
                if mapsLeftAnalogToDPad {
                    pad.buttons = Self.buttonsMappingLeftAnalogToDPad(
                        buttons: pad.buttons,
                        x: pad.leftAnalogX,
                        y: pad.leftAnalogY
                    )
                }
                let isExitChordPressed =
                    pad.isStartPressed && pad.isSelectPressed
                if exitChords[port].update(
                    startPressed: pad.isStartPressed,
                    selectPressed: pad.isSelectPressed
                ) {
                    exitRequested = true
                }
                if !isExitChordPressed {
                    pad.buttons.set(
                        .select,
                        when: pad.isSelectPressed
                    )
                    pad.buttons.set(
                        .start,
                        when: pad.isStartPressed
                    )
                }
                // R3/L3 are player-one transport shortcuts. Player two gets
                // ordinary stick-button input so multiplayer games can use it.
                pad.buttons.set(
                    .l3,
                    when:
                        pad.isLeftStickPressed
                        && (port != 0 || !enablesRewind)
                )
                pad.buttons.set(
                    .r3,
                    when:
                        pad.isRightStickPressed
                        && (port != 0 || !enablesFastForward)
                )
                state.controllerButtons = pad.buttons
                state.leftAnalogX = pad.leftAnalogX
                state.leftAnalogY = pad.leftAnalogY
                state.rightAnalogX = pad.rightAnalogX
                state.rightAnalogY = pad.rightAnalogY
            } else {
                _ = exitChords[port].update(
                    startPressed: false,
                    selectPressed: false
                )
            }
            state.polledButtons = state.controllerButtons
            controllerPorts[port] = state
        }

        controllerPorts[0].polledButtons |=
            keyboardButtons | pendingKeyboardPresses
        if routedPads[0] == nil {
            controllerPorts[0].leftAnalogX = digitalAxis(
                negative:
                    controllerPorts[0].polledButtons
                    & LibretroButton.left.mask != 0,
                positive:
                    controllerPorts[0].polledButtons
                    & LibretroButton.right.mask != 0
            )
            controllerPorts[0].leftAnalogY = digitalAxis(
                negative:
                    controllerPorts[0].polledButtons
                    & LibretroButton.up.mask != 0,
                positive:
                    controllerPorts[0].polledButtons
                    & LibretroButton.down.mask != 0
            )
        }

        let playerOne = routedPads[0]
        transportControls = .controller(
            leftThumbstickButtonPressed:
                playerOne?.isLeftStickPressed == true,
            rightThumbstickButtonPressed:
                playerOne?.isRightStickPressed == true,
            enablesRewind: enablesRewind,
            enablesFastForward: enablesFastForward
        )
        dsuPointer = remote?.pointer
        sensors = remote?.sensors ?? LibretroSensorValues()
        pendingKeyboardPresses = 0
    }

    /// Keeps physical controllers assigned to a player while they remain
    /// connected. `GCController.current` follows recent activity and would
    /// otherwise swap players whenever player two pressed a button.
    private func stableLocalControllers() -> [GCController] {
        let connected = GCController.controllers()
        for port in assignedLocalControllers.indices {
            guard let assigned = assignedLocalControllers[port] else {
                continue
            }
            if !connected.contains(where: { $0 === assigned }) {
                assignedLocalControllers[port] = nil
            }
        }

        var unassigned = connected.filter { controller in
            !assignedLocalControllers.contains {
                $0 === controller
            }
        }
        if
            assignedLocalControllers[0] == nil,
            let current = GCController.current,
            let index = unassigned.firstIndex(where: { $0 === current })
        {
            assignedLocalControllers[0] = unassigned.remove(at: index)
        }
        for port in assignedLocalControllers.indices
        where assignedLocalControllers[port] == nil {
            guard !unassigned.isEmpty else {
                break
            }
            assignedLocalControllers[port] = unassigned.removeFirst()
        }
        return assignedLocalControllers.compactMap { $0 }
    }

    private func resolvedPad(_ pad: LibretroGamepadInput) -> ResolvedPad {
        ResolvedPad(
            buttons: pad.buttons,
            isSelectPressed: pad.isSelectPressed,
            isStartPressed: pad.isStartPressed,
            isLeftStickPressed: pad.isLeftStickPressed,
            isRightStickPressed: pad.isRightStickPressed,
            leftAnalogX: analogAxis(pad.leftStickX),
            leftAnalogY: analogAxis(pad.leftStickY),
            rightAnalogX: analogAxis(pad.rightStickX),
            rightAnalogY: analogAxis(pad.rightStickY)
        )
    }

    private func resolvedPad(_ pad: LibretroDSUInput.Pad) -> ResolvedPad {
        ResolvedPad(
            buttons: pad.buttons,
            isSelectPressed: pad.isSelectPressed,
            isStartPressed: pad.isStartPressed,
            isLeftStickPressed: pad.isLeftStickPressed,
            isRightStickPressed: pad.isRightStickPressed,
            leftAnalogX: pad.leftAnalogX,
            leftAnalogY: pad.leftAnalogY,
            rightAnalogX: pad.rightAnalogX,
            rightAnalogY: pad.rightAnalogY
        )
    }

    static func faceButtonMask(
        buttonAPressed: Bool,
        buttonBPressed: Bool,
        buttonXPressed: Bool,
        buttonYPressed: Bool,
        layout: ControllerFaceButtonLayout
    ) -> UInt16 {
        var buttons: UInt16 = 0

        switch layout {
        case .standard:
            buttons.set(.b, when: buttonAPressed)
            buttons.set(.a, when: buttonBPressed)
            buttons.set(.y, when: buttonXPressed)
            buttons.set(.x, when: buttonYPressed)
        case .nintendo:
            buttons.set(.a, when: buttonAPressed)
            buttons.set(.b, when: buttonBPressed)
            buttons.set(.x, when: buttonXPressed)
            buttons.set(.y, when: buttonYPressed)
        }

        return buttons
    }

    static func buttonsMappingLeftAnalogToDPad(
        buttons: UInt16,
        x: Int16,
        y: Int16
    ) -> UInt16 {
        let directionalMask =
            LibretroButton.up.mask
            | LibretroButton.down.mask
            | LibretroButton.left.mask
            | LibretroButton.right.mask
        // A physical D-pad is authoritative. Avoid synthesizing the opposite
        // direction when a player rests a thumb on the stick while using it.
        guard buttons & directionalMask == 0 else {
            return buttons
        }

        let threshold = Int16.max / 2
        var mapped = buttons
        mapped.set(.left, when: x <= -threshold)
        mapped.set(.right, when: x >= threshold)
        mapped.set(.up, when: y <= -threshold)
        mapped.set(.down, when: y >= threshold)
        return mapped
    }

    func consumeExitRequest() -> Bool {
        lock.lock()
        defer {
            exitRequested = false
            lock.unlock()
        }
        return exitRequested
    }

    func currentTransportControls() -> LibretroTransportControls {
        lock.lock()
        defer { lock.unlock() }
        return transportControls
    }

    func setTransportControlsEnabled(
        rewind: Bool,
        fastForward: Bool
    ) {
        lock.lock()
        enablesRewind = rewind
        enablesFastForward = fastForward
        if !rewind {
            transportControls.isRewinding = false
        }
        if !fastForward {
            transportControls.isFastForwarding = false
        }
        lock.unlock()
    }

    func value(for id: UInt32, port: UInt32 = 0) -> Int16 {
        lock.lock()
        let buttons =
            Int(port) < controllerPorts.count
            ? controllerPorts[Int(port)].polledButtons
            : 0
        lock.unlock()

        if id == LibretroABI.joypadMaskID {
            return Int16(bitPattern: buttons)
        }

        guard id < 16 else {
            return 0
        }
        return buttons & (1 << UInt16(id)) == 0 ? 0 : 1
    }

    func pointerValue(for id: UInt32) -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        pointerRead = true

        // A live touchpad contact takes over the pointer; otherwise the mouse
        // keeps it.
        if let dsuPointer {
            return switch id {
            case LibretroABI.pointerXID:
                dsuPointer.x
            case LibretroABI.pointerYID:
                dsuPointer.y
            case LibretroABI.pointerPressedID:
                dsuPointer.isPressed ? 1 : 0
            default:
                0
            }
        }

        return switch id {
        case LibretroABI.pointerXID:
            pointerX
        case LibretroABI.pointerYID:
            pointerY
        case LibretroABI.pointerPressedID:
            pointerPressed && pointerInside ? 1 : 0
        default:
            0
        }
    }

    /// Cores opt in through `RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE` before
    /// reading, so a sensor that was never enabled stays silent.
    func setSensorEnabled(_ enabled: Bool, accelerometer: Bool) {
        lock.lock()
        if accelerometer {
            readsAccelerometer = enabled
        } else {
            readsGyroscope = enabled
        }
        lock.unlock()
    }

    func sensorValue(for id: UInt32) -> Float {
        lock.lock()
        defer { lock.unlock() }

        return switch id {
        case LibretroABI.accelerometerXID:
            readsAccelerometer ? sensors.accelerationX : 0
        case LibretroABI.accelerometerYID:
            readsAccelerometer ? sensors.accelerationY : 0
        case LibretroABI.accelerometerZID:
            readsAccelerometer ? sensors.accelerationZ : 0
        case LibretroABI.gyroscopeXID:
            readsGyroscope ? sensors.gyroscopeX : 0
        case LibretroABI.gyroscopeYID:
            readsGyroscope ? sensors.gyroscopeY : 0
        case LibretroABI.gyroscopeZID:
            readsGyroscope ? sensors.gyroscopeZ : 0
        default:
            0
        }
    }

    func analogValue(
        index: UInt32,
        id: UInt32,
        port: UInt32 = 0
    ) -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        guard Int(port) < controllerPorts.count else {
            return 0
        }
        let state = controllerPorts[Int(port)]

        return switch (index, id) {
        case (LibretroABI.analogLeftIndex, LibretroABI.analogXID):
            state.leftAnalogX
        case (LibretroABI.analogLeftIndex, LibretroABI.analogYID):
            state.leftAnalogY
        case (LibretroABI.analogRightIndex, LibretroABI.analogXID):
            state.rightAnalogX
        case (LibretroABI.analogRightIndex, LibretroABI.analogYID):
            state.rightAnalogY
        default:
            0
        }
    }

    private func analogAxis(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamping: Int(clamped * Float(Int16.max)))
    }

    private func digitalAxis(negative: Bool, positive: Bool) -> Int16 {
        switch (negative, positive) {
        case (true, false):
            Int16.min + 1
        case (false, true):
            Int16.max
        default:
            0
        }
    }

    private func dominantAxis(_ first: Int16, _ second: Int16) -> Int16 {
        abs(Int(first)) >= abs(Int(second)) ? first : second
    }
}

/// A single frame of state read from a locally attached controller, captured
/// before the input lock is taken so the GameController framework is never
/// queried while the emulator thread holds it.
private struct LibretroGamepadInput {
    var buttons: UInt16 = 0
    var isSelectPressed = false
    var isStartPressed = false
    var isLeftStickPressed = false
    var isRightStickPressed = false
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0

    init?(controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            return nil
        }

        buttons.set(.up, when: gamepad.dpad.up.isPressed)
        buttons.set(.down, when: gamepad.dpad.down.isPressed)
        buttons.set(.left, when: gamepad.dpad.left.isPressed)
        buttons.set(.right, when: gamepad.dpad.right.isPressed)
        buttons |= LibretroInputState.faceButtonMask(
            buttonAPressed: gamepad.buttonA.isPressed,
            buttonBPressed: gamepad.buttonB.isPressed,
            buttonXPressed: gamepad.buttonX.isPressed,
            buttonYPressed: gamepad.buttonY.isPressed,
            layout: ControllerFaceButtonLayout.resolve(
                vendorName: controller.vendorName,
                productCategory: controller.productCategory
            )
        )
        buttons.set(.l, when: gamepad.leftShoulder.isPressed)
        buttons.set(.r, when: gamepad.rightShoulder.isPressed)
        buttons.set(.l2, when: gamepad.leftTrigger.isPressed)
        buttons.set(.r2, when: gamepad.rightTrigger.isPressed)

        isSelectPressed = gamepad.buttonOptions?.isPressed == true
        isStartPressed = gamepad.buttonMenu.isPressed
        isLeftStickPressed = gamepad.leftThumbstickButton?.isPressed == true
        isRightStickPressed = gamepad.rightThumbstickButton?.isPressed == true

        leftStickX = gamepad.leftThumbstick.xAxis.value
        leftStickY = -gamepad.leftThumbstick.yAxis.value
        rightStickX = gamepad.rightThumbstick.xAxis.value
        rightStickY = -gamepad.rightThumbstick.yAxis.value
    }
}

enum LibretroButton: UInt32, Sendable {
    case b = 0
    case y = 1
    case select = 2
    case start = 3
    case up = 4
    case down = 5
    case left = 6
    case right = 7
    case a = 8
    case x = 9
    case l = 10
    case r = 11
    case l2 = 12
    case r2 = 13
    case l3 = 14
    case r3 = 15

    var mask: UInt16 {
        1 << UInt16(rawValue)
    }
}

private extension UInt16 {
    mutating func set(_ button: LibretroButton, when condition: Bool) {
        if condition {
            self |= button.mask
        }
    }
}

enum LibretroExitMode: Equatable, Sendable {
    case automatic
    case explicitStop

    var createsResumeState: Bool {
        self == .automatic
    }
}

@MainActor
@Observable
final class LibretroSession {
    enum Phase: Equatable {
        case idle
        case starting
        case running(coreName: String, framesPerSecond: Double)
        case stopped
        case failed(String)
    }

    enum SaveSyncPhase: Equatable {
        case idle
        case syncing
        case unchanged
        case uploaded
        case failed(String)
    }

    let request: LibretroRunRequest
    let videoBuffer = LibretroVideoBuffer()
    let input = LibretroInputState()
    private let displaySleep = DisplaySleepAssertion()

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var isMuted = false
    private(set) var message: String?
    private(set) var hasQuickState = false
    private(set) var canRewind = false
    private(set) var saveSyncPhase: SaveSyncPhase = .idle
    private(set) var shouldClosePlayer = false

    var allowsRewind: Bool {
        request.allowsRewind
    }

    private let engine: LibretroEngine
    private let syncCartridgeSave:
        @Sendable (CartridgeSaveSyncConfiguration) async throws
            -> CartridgeSaveSyncOutcome

    init(
        request: LibretroRunRequest,
        installation: LibretroInstallation? = nil,
        syncCartridgeSave:
            @escaping @Sendable (CartridgeSaveSyncConfiguration) async throws
                -> CartridgeSaveSyncOutcome = { _ in .unchanged }
    ) {
        self.request = request
        self.syncCartridgeSave = syncCartridgeSave
        engine = LibretroEngine(
            request: request,
            videoBuffer: videoBuffer,
            input: input,
            installation: installation
        )
        hasQuickState = engine.hasQuickState
        // The DSU connection is owned by the app, not the session, so the same
        // pad drives Big Picture and the running game.
        input.setPadSource(DSUConnection.shared)
    }

    func start() {
        switch phase {
        case .idle, .stopped, .failed:
            break
        case .starting, .running:
            return
        }

        phase = .starting
        isPaused = false
        isMuted = false
        canRewind = false
        shouldClosePlayer = false
        message = nil
        OpenVaultLog.libretro.notice(
            "Starting core \(self.request.coreID, privacy: .public)"
        )
        engine.start { [self] event in
            Task { @MainActor [self] in
                receive(event)
            }
        }
    }

    func togglePause() {
        guard case .running = phase else {
            return
        }
        isPaused.toggle()
        engine.setPaused(isPaused)
        // A paused game left on screen is someone who walked away, so let the
        // display dim as it normally would.
        if isPaused {
            displaySleep.end()
        } else {
            displaySleep.begin(reason: "Playing \(request.title)")
         }
    }

    func reset() {
        guard case .running = phase else {
            return
        }
        engine.reset()
        canRewind = false
        message = "Game reset."
    }

    func rewind() {
        guard case .running = phase, canRewind else {
            return
        }
        engine.rewind()
    }

    func setTransportControlsEnabled(
        rewind: Bool,
        fastForward: Bool
    ) {
        input.setTransportControlsEnabled(
            rewind: rewind,
            fastForward: fastForward
        )
    }

    func saveQuickState() {
        guard case .running = phase else {
            return
        }
        engine.saveQuickState()
    }

    func loadQuickState() {
        guard case .running = phase, hasQuickState else {
            return
        }
        engine.loadQuickState()
    }

    func stop() {
        engine.stop()
        input.releaseKeyboard()
        displaySleep.end()
    }

    func exitPlayer(mode: LibretroExitMode = .automatic) {
        guard !shouldClosePlayer else {
            return
        }
        shouldClosePlayer = true
        if mode.createsResumeState, case .running = phase {
            message = "Saving resume state…"
            engine.saveQuickStateAndStop()
        } else {
            message = "Closing game…"
            stop()
        }
    }

    func toggleMute() {
        guard case .running = phase else {
            return
        }
        isMuted.toggle()
        engine.setMuted(isMuted)
    }

    var isReadyToClosePlayer: Bool {
        switch phase {
        case .idle, .stopped, .failed:
            true
        case .starting, .running:
            false
        }
    }

    func retrySaveSync() {
        guard case .failed = saveSyncPhase else {
            return
        }
        synchronizeCartridgeSave()
    }

    private func receive(_ event: LibretroEngine.Event) {
        switch event {
        case let .running(coreName, framesPerSecond):
            phase = .running(coreName: coreName, framesPerSecond: framesPerSecond)
            saveSyncPhase = .idle
            displaySleep.begin(reason: "Playing \(request.title)")
            OpenVaultLog.libretro.notice(
                "Core \(coreName, privacy: .public) is running at \(framesPerSecond, privacy: .public) FPS"
            )
        case .stopped:
            phase = .stopped
            isPaused = false
            isMuted = false
            canRewind = false
            displaySleep.end()
            if request.saveSync != nil, saveSyncPhase == .idle {
                synchronizeCartridgeSave()
            }
            OpenVaultLog.libretro.notice("Libretro session stopped")
        case let .failed(error):
            phase = .failed(error)
            isPaused = false
            isMuted = false
            canRewind = false
            displaySleep.end()
            OpenVaultLog.libretro.error("Libretro session failed: \(error)")
        case .quickStateSaved:
            hasQuickState = true
            OpenVaultLog.libretro.info("Quick state saved")
            message = "Quick state saved locally."
        case .quickStateLoaded:
            message = "Quick state restored."
        case let .rewindAvailabilityChanged(isAvailable):
            canRewind = isAvailable
        case let .rewound(canContinue):
            canRewind = canContinue
            message = canContinue
                ? "Rewound about one second."
                : "Rewound to the beginning of available history."
        case let .notice(text):
            message = text
        case .saveMemoryPersisted:
            synchronizeCartridgeSave()
        case .controllerExitRequested:
            OpenVaultLog.libretro.notice(
                "Start and Select pressed; requesting clean exit"
            )
            exitPlayer()
        }
    }

    private func synchronizeCartridgeSave() {
        guard
            let configuration = request.saveSync,
            saveSyncPhase != .syncing
        else {
            return
        }

        saveSyncPhase = .syncing
        let operation = syncCartridgeSave
        Task {
            do {
                let outcome = try await operation(configuration)
                switch outcome {
                case .unchanged:
                    saveSyncPhase = .unchanged
                case .uploaded:
                    saveSyncPhase = .uploaded
                }
            } catch {
                saveSyncPhase = .failed(error.localizedDescription)
            }
        }
    }
}

private enum LibretroRuntimeError: LocalizedError {
    case alreadyRunning
    case couldNotLoadCore(String)
    case couldNotStageContent(String)
    case missingSymbol(String)
    case unsupportedAPIVersion(UInt32)
    case contentRejected
    case invalidSystemInformation
    case couldNotInitializeHardwareContext
    case unsupportedPixelFormat(Int32)
    case stateUnavailable
    case stateOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "OpenVault currently supports one active Libretro session."
        case let .couldNotLoadCore(reason):
            "The Libretro core could not be loaded: \(reason)"
        case let .couldNotStageContent(reason):
            "The game could not be prepared for this Libretro core: \(reason)"
        case let .missingSymbol(symbol):
            "The bundled core is invalid because it does not export \(symbol)."
        case let .unsupportedAPIVersion(version):
            "The core uses unsupported Libretro API version \(version)."
        case .contentRejected:
            "The core rejected this game file."
        case .invalidSystemInformation:
            "The core returned invalid system or video information."
        case .couldNotInitializeHardwareContext:
            "The core's hardware-rendering context could not be initialized."
        case let .unsupportedPixelFormat(format):
            "The core requested unsupported pixel format \(format)."
        case .stateUnavailable:
            "This core does not expose save states for the current game."
        case let .stateOperationFailed(reason):
            "The save state operation failed: \(reason)"
        }
    }
}

final class LibretroStagedContent {
    // Several otherwise modern cores still use 256-byte path buffers internally.
    // Leave room for a descriptor (CUE/M3U) to resolve adjacent disc files.
    private static let maximumUnstagedPathLength = 192

    let contentURL: URL?

    private let stagingDirectory: URL?

    private init(contentURL: URL?, stagingDirectory: URL?) {
        self.contentURL = contentURL
        self.stagingDirectory = stagingDirectory
    }

    deinit {
        if let stagingDirectory {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
    }

    static func prepare(
        contentURL: URL?,
        needsFullPath: Bool,
        fileManager: FileManager = .default
    ) throws -> LibretroStagedContent {
        guard
            needsFullPath,
            let contentURL,
            contentURL.path.utf8.count >= maximumUnstagedPathLength
        else {
            return LibretroStagedContent(
                contentURL: contentURL,
                stagingDirectory: nil
            )
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appending(path: "ov-play", directoryHint: .isDirectory)
        let stagingDirectory = stagingRoot.appending(
            path: String(UUID().uuidString.prefix(8)),
            directoryHint: .isDirectory
        )

        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )

            let sourceDirectory = contentURL.deletingLastPathComponent()
            let siblings = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for sibling in siblings {
                let values = try sibling.resourceValues(
                    forKeys: [.isRegularFileKey]
                )
                guard values.isRegularFile == true else {
                    continue
                }
                try fileManager.createSymbolicLink(
                    at: stagingDirectory.appending(path: sibling.lastPathComponent),
                    withDestinationURL: sibling
                )
            }

            let originalNameURL = stagingDirectory.appending(
                path: contentURL.lastPathComponent
            )
            let stagedURL: URL
            if originalNameURL.path.utf8.count < maximumUnstagedPathLength {
                // Arcade cores identify a ROM set by its archive basename.
                // Preserve names such as `digdug.zip` when shortening the
                // containing sandbox path.
                stagedURL = originalNameURL
                if !fileManager.fileExists(atPath: stagedURL.path) {
                    try fileManager.createSymbolicLink(
                        at: stagedURL,
                        withDestinationURL: contentURL
                    )
                }
            } else {
                let fileExtension = contentURL.pathExtension
                var launchName = fileExtension.isEmpty
                    ? "content"
                    : "content.\(fileExtension)"
                if launchName == contentURL.lastPathComponent {
                    launchName = fileExtension.isEmpty
                        ? "launch"
                        : "launch.\(fileExtension)"
                }
                stagedURL = stagingDirectory.appending(path: launchName)
                try fileManager.createSymbolicLink(
                    at: stagedURL,
                    withDestinationURL: contentURL
                )
            }

            guard
                stagedURL.path.utf8.count < maximumUnstagedPathLength,
                fileManager.fileExists(atPath: stagedURL.path)
            else {
                throw LibretroRuntimeError.couldNotStageContent(
                    "The temporary compatibility path is still too long."
                )
            }

            OpenVaultLog.libretro.notice(
                "Using a short compatibility path for core content"
            )
            return LibretroStagedContent(
                contentURL: stagedURL,
                stagingDirectory: stagingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            if let runtimeError = error as? LibretroRuntimeError {
                throw runtimeError
            }
            throw LibretroRuntimeError.couldNotStageContent(
                error.localizedDescription
            )
        }
    }
}

private enum LibretroABI {
    static let apiVersion: UInt32 = 1
    static let joypadDevice = LibretroControllerDevice.joypad
    static let analogDevice: UInt32 = 5
    static let joypadMaskID: UInt32 = 256
    static let analogLeftIndex: UInt32 = 0
    static let analogRightIndex: UInt32 = 1
    static let analogXID: UInt32 = 0
    static let analogYID: UInt32 = 1
    static let pointerDevice: UInt32 = 6
    static let pointerXID: UInt32 = 0
    static let pointerYID: UInt32 = 1
    static let pointerPressedID: UInt32 = 2
    static let accelerometerXID: UInt32 = 0
    static let accelerometerYID: UInt32 = 1
    static let accelerometerZID: UInt32 = 2
    static let gyroscopeXID: UInt32 = 3
    static let gyroscopeYID: UInt32 = 4
    static let gyroscopeZID: UInt32 = 5
    static let saveRAM: UInt32 = 0
    /// Commands above this bit are still marked experimental in `libretro.h`.
    static let experimentalCommand: UInt32 = 0x1_0000

    enum SensorAction: UInt32 {
        case enableAccelerometer = 0
        case disableAccelerometer = 1
        case enableGyroscope = 2
        case disableGyroscope = 3
    }

    enum PixelFormat: Int32 {
        case zeroRGB1555 = 0
        case xRGB8888 = 1
        case rgb565 = 2
    }

    enum EnvironmentCommand: UInt32 {
        case getCanDupe = 3
        case setMessage = 6
        case shutdown = 7
        case getSystemDirectory = 9
        case setPixelFormat = 10
        case setInputDescriptors = 11
        case setHardwareRender = 14
        case setKeyboardCallback = 12
        case getVariable = 15
        case setVariables = 16
        case getVariableUpdate = 17
        case setSupportNoGame = 18
        case setFrameTimeCallback = 21
        case getLogInterface = 27
        case getCoreAssetsDirectory = 30
        case getSaveDirectory = 31
        case setSystemAVInfo = 32
        case setGeometry = 37
        case getLanguage = 39
        case getCurrentSoftwareFramebuffer = 40
        case getVFSInterface = 45
        case getTargetRefreshRate = 50
        case getInputBitmasks = 51
        case getPreferredHardwareRender = 56
        /// `28 | RETRO_ENVIRONMENT_EXPERIMENTAL`, which is how `libretro.h`
        /// spells the sensor interface.
        case getSensorInterface = 65_564
    }

    enum HardwareContext: Int32 {
        case none = 0
        case openGL = 1
        case openGLCore = 3
    }
}

private typealias RetroEnvironmentCallback =
    @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
private typealias RetroVideoCallback =
    @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void
private typealias RetroAudioSampleCallback =
    @convention(c) (Int16, Int16) -> Void
private typealias RetroAudioBatchCallback =
    @convention(c) (UnsafePointer<Int16>?, Int) -> Int
private typealias RetroInputPollCallback =
    @convention(c) () -> Void
typealias RetroKeyboardEventCallback =
    @convention(c) (Bool, UInt32, UInt32, UInt16) -> Void

private typealias RetroInputStateCallback =
    @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16
private typealias RetroSetSensorStateCallback =
    @convention(c) (UInt32, UInt32, UInt32) -> Bool
private typealias RetroSensorGetInputCallback =
    @convention(c) (UInt32, UInt32) -> Float
private typealias RetroHardwareContextCallback =
    @convention(c) () -> Void
private typealias RetroHardwareFramebufferCallback =
    @convention(c) () -> UInt
private typealias RetroHardwareProc =
    @convention(c) () -> Void
private typealias RetroHardwareProcAddressCallback =
    @convention(c) (UnsafePointer<CChar>?) -> RetroHardwareProc?

/// `struct retro_sensor_interface`, filled in for the core on request.
private struct RetroSensorInterface {
    var setSensorState: RetroSetSensorStateCallback?
    var getSensorInput: RetroSensorGetInputCallback?
}

private struct RetroHardwareRenderCallback {
    var contextType: Int32
    var contextReset: RetroHardwareContextCallback?
    var getCurrentFramebuffer: RetroHardwareFramebufferCallback?
    var getProcAddress: RetroHardwareProcAddressCallback?
    var depth: Bool
    var stencil: Bool
    var bottomLeftOrigin: Bool
    var versionMajor: UInt32
    var versionMinor: UInt32
    var cacheContext: Bool
    var contextDestroy: RetroHardwareContextCallback?
    var debugContext: Bool
}

private protocol LibretroCallbackTarget: AnyObject {
    func environment(command: UInt32, data: UnsafeMutableRawPointer?) -> Bool
    func video(data: UnsafeRawPointer?, width: UInt32, height: UInt32, pitch: Int)
    func audio(left: Int16, right: Int16)
    func audio(data: UnsafePointer<Int16>?, frames: Int) -> Int
    func pollInput()
    func input(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16
    func setSensorState(port: UInt32, action: UInt32, rate: UInt32) -> Bool
    func sensorInput(port: UInt32, id: UInt32) -> Float
    func currentHardwareFramebuffer() -> UInt
    func hardwareProcAddress(_ name: UnsafePointer<CChar>?) -> RetroHardwareProc?
}

private final class LibretroCallbackRouter: @unchecked Sendable {
    static let shared = LibretroCallbackRouter()

    private let lock = NSLock()
    private weak var target: (any LibretroCallbackTarget)?

    func install(_ target: any LibretroCallbackTarget) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.target == nil else {
            return false
        }
        self.target = target
        return true
    }

    func remove(_ target: any LibretroCallbackTarget) {
        lock.lock()
        if self.target === target {
            self.target = nil
        }
        lock.unlock()
    }

    func currentTarget() -> (any LibretroCallbackTarget)? {
        lock.lock()
        defer { lock.unlock() }
        return target
    }
}

private let libretroEnvironmentCallback: RetroEnvironmentCallback = { command, data in
    LibretroCallbackRouter.shared.currentTarget()?
        .environment(command: command, data: data) ?? false
}

private let libretroVideoCallback: RetroVideoCallback = { data, width, height, pitch in
    LibretroCallbackRouter.shared.currentTarget()?
        .video(data: data, width: width, height: height, pitch: pitch)
}

private let libretroAudioSampleCallback: RetroAudioSampleCallback = { left, right in
    LibretroCallbackRouter.shared.currentTarget()?.audio(left: left, right: right)
}

private let libretroAudioBatchCallback: RetroAudioBatchCallback = { data, frames in
    LibretroCallbackRouter.shared.currentTarget()?
        .audio(data: data, frames: frames) ?? 0
}

private let libretroInputPollCallback: RetroInputPollCallback = {
    LibretroCallbackRouter.shared.currentTarget()?.pollInput()
}

private let libretroInputStateCallback: RetroInputStateCallback = { port, device, index, id in
    LibretroCallbackRouter.shared.currentTarget()?
        .input(port: port, device: device, index: index, id: id) ?? 0
}

private let libretroSetSensorStateCallback: RetroSetSensorStateCallback = { port, action, rate in
    LibretroCallbackRouter.shared.currentTarget()?
        .setSensorState(port: port, action: action, rate: rate) ?? false
}

private let libretroSensorInputCallback: RetroSensorGetInputCallback = { port, id in
    LibretroCallbackRouter.shared.currentTarget()?
        .sensorInput(port: port, id: id) ?? 0
}

private let libretroHardwareFramebufferCallback: RetroHardwareFramebufferCallback = {
    LibretroCallbackRouter.shared.currentTarget()?.currentHardwareFramebuffer() ?? 0
}

private let libretroHardwareProcAddressCallback: RetroHardwareProcAddressCallback = { name in
    LibretroCallbackRouter.shared.currentTarget()?.hardwareProcAddress(name)
}

private final class LibretroCore {
    struct SystemInfo {
        let name: String
        let version: String
        let validExtensions: [String]
        let needsFullPath: Bool
    }

    struct AVInfo {
        let width: Int
        let height: Int
        let maximumWidth: Int
        let maximumHeight: Int
        let aspectRatio: Float
        let framesPerSecond: Double
        let sampleRate: Double
    }

    private typealias SetEnvironment =
        @convention(c) (RetroEnvironmentCallback) -> Void
    private typealias SetVideo =
        @convention(c) (RetroVideoCallback) -> Void
    private typealias SetAudioSample =
        @convention(c) (RetroAudioSampleCallback) -> Void
    private typealias SetAudioBatch =
        @convention(c) (RetroAudioBatchCallback) -> Void
    private typealias SetInputPoll =
        @convention(c) (RetroInputPollCallback) -> Void
    private typealias SetInputState =
        @convention(c) (RetroInputStateCallback) -> Void
    private typealias SetControllerPortDevice =
        @convention(c) (UInt32, UInt32) -> Void
    private typealias VoidFunction = @convention(c) () -> Void
    private typealias APIVersion = @convention(c) () -> UInt32
    private typealias WriteInfo = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias LoadGame = @convention(c) (UnsafeRawPointer?) -> Bool
    private typealias SerializeSize = @convention(c) () -> Int
    private typealias Serialize =
        @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
    private typealias Unserialize =
        @convention(c) (UnsafeRawPointer?, Int) -> Bool
    private typealias GetMemoryData =
        @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    private typealias GetMemorySize = @convention(c) (UInt32) -> Int

    private let handle: UnsafeMutableRawPointer
    private let setEnvironmentFunction: SetEnvironment
    private let setVideoFunction: SetVideo
    private let setAudioSampleFunction: SetAudioSample
    private let setAudioBatchFunction: SetAudioBatch
    private let setInputPollFunction: SetInputPoll
    private let setInputStateFunction: SetInputState
    private let setControllerPortDeviceFunction: SetControllerPortDevice
    private let initializeFunction: VoidFunction
    private let deinitializeFunction: VoidFunction
    private let apiVersionFunction: APIVersion
    private let systemInfoFunction: WriteInfo
    private let avInfoFunction: WriteInfo
    private let resetFunction: VoidFunction
    private let runFunction: VoidFunction
    private let loadGameFunction: LoadGame
    private let unloadGameFunction: VoidFunction
    private let serializeSizeFunction: SerializeSize
    private let serializeFunction: Serialize
    private let unserializeFunction: Unserialize
    private let getMemoryDataFunction: GetMemoryData
    private let getMemorySizeFunction: GetMemorySize

    init(url: URL) throws {
        dlerror()
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "Unknown loader error."
            throw LibretroRuntimeError.couldNotLoadCore(reason)
        }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            dlerror()
            guard let pointer = dlsym(handle, name) else {
                throw LibretroRuntimeError.missingSymbol(name)
            }
            return unsafeBitCast(pointer, to: type)
        }

        do {
            setEnvironmentFunction = try symbol("retro_set_environment", as: SetEnvironment.self)
            setVideoFunction = try symbol("retro_set_video_refresh", as: SetVideo.self)
            setAudioSampleFunction = try symbol("retro_set_audio_sample", as: SetAudioSample.self)
            setAudioBatchFunction = try symbol(
                "retro_set_audio_sample_batch",
                as: SetAudioBatch.self
            )
            setInputPollFunction = try symbol("retro_set_input_poll", as: SetInputPoll.self)
            setInputStateFunction = try symbol("retro_set_input_state", as: SetInputState.self)
            setControllerPortDeviceFunction = try symbol(
                "retro_set_controller_port_device",
                as: SetControllerPortDevice.self
            )
            initializeFunction = try symbol("retro_init", as: VoidFunction.self)
            deinitializeFunction = try symbol("retro_deinit", as: VoidFunction.self)
            apiVersionFunction = try symbol("retro_api_version", as: APIVersion.self)
            systemInfoFunction = try symbol("retro_get_system_info", as: WriteInfo.self)
            avInfoFunction = try symbol("retro_get_system_av_info", as: WriteInfo.self)
            resetFunction = try symbol("retro_reset", as: VoidFunction.self)
            runFunction = try symbol("retro_run", as: VoidFunction.self)
            loadGameFunction = try symbol("retro_load_game", as: LoadGame.self)
            unloadGameFunction = try symbol("retro_unload_game", as: VoidFunction.self)
            serializeSizeFunction = try symbol("retro_serialize_size", as: SerializeSize.self)
            serializeFunction = try symbol("retro_serialize", as: Serialize.self)
            unserializeFunction = try symbol("retro_unserialize", as: Unserialize.self)
            getMemoryDataFunction = try symbol(
                "retro_get_memory_data",
                as: GetMemoryData.self
            )
            getMemorySizeFunction = try symbol(
                "retro_get_memory_size",
                as: GetMemorySize.self
            )
        } catch {
            dlclose(handle)
            throw error
        }

        let version = apiVersionFunction()
        guard version == LibretroABI.apiVersion else {
            dlclose(handle)
            throw LibretroRuntimeError.unsupportedAPIVersion(version)
        }
    }

    deinit {
        dlclose(handle)
    }

    func installCallbacks() {
        setEnvironmentFunction(libretroEnvironmentCallback)
        setVideoFunction(libretroVideoCallback)
        setAudioSampleFunction(libretroAudioSampleCallback)
        setAudioBatchFunction(libretroAudioBatchCallback)
        setInputPollFunction(libretroInputPollCallback)
        setInputStateFunction(libretroInputStateCallback)
    }

    func initialize() {
        initializeFunction()
    }

    func deinitialize() {
        deinitializeFunction()
    }

    func systemInfo() throws -> SystemInfo {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        systemInfoFunction(storage)

        guard let namePointer = storage.load(as: UnsafePointer<CChar>?.self) else {
            throw LibretroRuntimeError.invalidSystemInformation
        }
        let versionPointer = storage.load(
            fromByteOffset: 8,
            as: UnsafePointer<CChar>?.self
        )
        let extensionsPointer = storage.load(
            fromByteOffset: 16,
            as: UnsafePointer<CChar>?.self
        )

        return SystemInfo(
            name: String(cString: namePointer),
            version: versionPointer.map(String.init(cString:)) ?? "",
            validExtensions: extensionsPointer
                .map { String(cString: $0).split(separator: "|").map(String.init) }
                ?? [],
            needsFullPath: storage.load(fromByteOffset: 24, as: Bool.self)
        )
    }

    func loadGame(contentURL: URL?, needsFullPath: Bool) throws {
        guard let contentURL else {
            guard loadGameFunction(nil) else {
                throw LibretroRuntimeError.contentRejected
            }
            return
        }

        let content = needsFullPath ? nil : try Data(contentsOf: contentURL)
        let path = strdup(contentURL.path)
        defer { free(path) }

        let loaded: Bool
        if let content {
            loaded = content.withUnsafeBytes { bytes in
                loadGame(path: path, data: bytes.baseAddress, size: bytes.count)
            }
        } else {
            loaded = loadGame(path: path, data: nil, size: 0)
        }

        guard loaded else {
            throw LibretroRuntimeError.contentRejected
        }
    }

    private func loadGame(
        path: UnsafeMutablePointer<CChar>?,
        data: UnsafeRawPointer?,
        size: Int
    ) -> Bool {
        let info = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { info.deallocate() }
        info.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        info.storeBytes(of: UnsafePointer(path), toByteOffset: 0, as: UnsafePointer<CChar>?.self)
        info.storeBytes(of: data, toByteOffset: 8, as: UnsafeRawPointer?.self)
        info.storeBytes(of: size, toByteOffset: 16, as: Int.self)
        info.storeBytes(
            of: Optional<UnsafePointer<CChar>>.none,
            toByteOffset: 24,
            as: UnsafePointer<CChar>?.self
        )
        return loadGameFunction(UnsafeRawPointer(info))
    }

    func unloadGame() {
        unloadGameFunction()
    }

    /// Declares which device is attached to a controller port.
    ///
    /// Cores with a single fixed controller layout read the RetroPad
    /// unconditionally and ignore this, but cores that emulate real port
    /// hardware bind their input only in response to it. Dolphin, for example,
    /// installs the GameCube Serial Interface device and every pad control
    /// expression here; without the call it leaves the port empty and no input
    /// reaches the emulated console. Content must already be loaded, because
    /// the device a port accepts depends on whether the title is GameCube or
    /// Wii.
    func setControllerPortDevice(port: UInt32, device: UInt32) {
        setControllerPortDeviceFunction(port, device)
    }

    func avInfo() throws -> AVInfo {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
        avInfoFunction(storage)

        let width = Int(storage.load(fromByteOffset: 0, as: UInt32.self))
        let height = Int(storage.load(fromByteOffset: 4, as: UInt32.self))
        let maximumWidth = Int(storage.load(fromByteOffset: 8, as: UInt32.self))
        let maximumHeight = Int(storage.load(fromByteOffset: 12, as: UInt32.self))
        let framesPerSecond = storage.load(fromByteOffset: 24, as: Double.self)

        guard width > 0, height > 0, framesPerSecond > 0 else {
            throw LibretroRuntimeError.invalidSystemInformation
        }

        return AVInfo(
            width: width,
            height: height,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            aspectRatio: storage.load(fromByteOffset: 16, as: Float.self),
            framesPerSecond: framesPerSecond,
            sampleRate: storage.load(fromByteOffset: 32, as: Double.self)
        )
    }

    func run() {
        runFunction()
    }

    func reset() {
        resetFunction()
    }

    func saveState() throws -> Data {
        let size = serializeSizeFunction()
        guard size > 0 else {
            throw LibretroRuntimeError.stateUnavailable
        }

        var data = Data(count: size)
        let succeeded = data.withUnsafeMutableBytes {
            serializeFunction($0.baseAddress, size)
        }
        guard succeeded else {
            throw LibretroRuntimeError.stateOperationFailed("The core refused to serialize.")
        }
        return data
    }

    func loadState(_ data: Data) throws {
        let succeeded = data.withUnsafeBytes {
            unserializeFunction($0.baseAddress, $0.count)
        }
        guard succeeded else {
            throw LibretroRuntimeError.stateOperationFailed("The core refused to restore it.")
        }
    }

    func saveMemory() -> (UnsafeMutableRawPointer, Int)? {
        let size = getMemorySizeFunction(LibretroABI.saveRAM)
        guard size > 0, let data = getMemoryDataFunction(LibretroABI.saveRAM) else {
            return nil
        }
        return (data, size)
    }
}

private final class LibretroAudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var individualSamples: [Int16] = []
    private var isUserMuted = false
    private var suppressesTransportAudio = false

    private var suppressesAudio: Bool {
        isUserMuted || suppressesTransportAudio
    }

    func configure(sampleRate: Double) throws {
        guard sampleRate > 0 else {
            return
        }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )
        guard let format else {
            throw LibretroRuntimeError.invalidSystemInformation
        }

        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func append(left: Int16, right: Int16) {
        guard !suppressesAudio else {
            return
        }
        individualSamples.append(left)
        individualSamples.append(right)
        if individualSamples.count >= 1_024 {
            individualSamples.withUnsafeBufferPointer {
                schedule(samples: $0.baseAddress, frames: $0.count / 2)
            }
            individualSamples.removeAll(keepingCapacity: true)
        }
    }

    func append(samples: UnsafePointer<Int16>?, frames: Int) {
        guard !suppressesAudio else {
            return
        }
        schedule(samples: samples, frames: frames)
    }

    func setTransportAudioSuppressed(_ shouldSuppressAudio: Bool) {
        guard suppressesTransportAudio != shouldSuppressAudio else {
            return
        }
        suppressesTransportAudio = shouldSuppressAudio
        flush()
    }

    func setUserMuted(_ isMuted: Bool) {
        guard isUserMuted != isMuted else {
            return
        }
        isUserMuted = isMuted
        flush()
    }

    func discardPendingSamples() {
        individualSamples.removeAll(keepingCapacity: true)
    }

    func flush() {
        individualSamples.removeAll(keepingCapacity: true)
        player.stop()
        if engine.isRunning {
            player.play()
        }
    }

    func stop() {
        if !individualSamples.isEmpty {
            individualSamples.withUnsafeBufferPointer {
                schedule(samples: $0.baseAddress, frames: $0.count / 2)
            }
            individualSamples.removeAll()
        }
        isUserMuted = false
        suppressesTransportAudio = false
        player.stop()
        engine.stop()
    }

    private func schedule(samples: UnsafePointer<Int16>?, frames: Int) {
        guard
            frames > 0,
            let samples,
            let format,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ),
            let channels = buffer.floatChannelData
        else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frames)
        let scale = Float(Int16.max)
        for index in 0 ..< frames {
            channels[0][index] = Float(samples[index * 2]) / scale
            channels[1][index] = Float(samples[index * 2 + 1]) / scale
        }
        player.scheduleBuffer(buffer)
    }
}

/// Provides the OpenGL 4.1 context required by hardware-rendered Libretro cores.
///
/// The core renders into an offscreen framebuffer. OpenVault reads completed
/// frames back into its existing Metal presentation path, keeping the SwiftUI
/// window and fullscreen behavior shared with software-rendered cores.
private final class LibretroOpenGLRenderer: @unchecked Sendable {
    private static let maximumDimension: GLsizei = 4_096
    private let openGLLibrary = dlopen(
        "/System/Library/Frameworks/OpenGL.framework/OpenGL",
        RTLD_LAZY | RTLD_LOCAL
    )

    private let context: CGLContextObj
    private var framebuffer: GLuint = 0
    private var colorTexture: GLuint = 0
    private var depthStencilBuffer: GLuint = 0

    /// Creates a context matching the version the core asked for.
    ///
    /// macOS tops out at OpenGL 4.1, so a 4.x context is missing the direct
    /// state access entry points that 4.2 and later define. A core that asks
    /// for 3.2 but is handed a 4.x context can conclude those functions exist,
    /// look them up, receive nothing, and call through the null pointer on its
    /// first frame. Honouring the requested version keeps such a core on the
    /// path it asked for.
    init?(majorVersion: UInt32) {
        let profile =
            majorVersion >= 4
            ? kCGLOGLPVersion_GL4_Core
            : kCGLOGLPVersion_3_2_Core
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(rawValue: UInt32(profile.rawValue)),
            kCGLPFAAccelerated,
            CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var pixelFormatCount: GLint = 0
        guard
            CGLChoosePixelFormat(
                &attributes,
                &pixelFormat,
                &pixelFormatCount
            ) == kCGLNoError,
            let pixelFormat
        else {
            return nil
        }
        defer {
            CGLDestroyPixelFormat(pixelFormat)
        }

        var context: CGLContextObj?
        guard
            CGLCreateContext(pixelFormat, nil, &context) == kCGLNoError,
            let context
        else {
            return nil
        }
        self.context = context

        guard makeCurrent() else {
            CGLDestroyContext(context)
            return nil
        }

        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

        glGenTextures(1, &colorTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), colorTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glTexImage2D(
            GLenum(GL_TEXTURE_2D),
            0,
            GL_RGBA8,
            Self.maximumDimension,
            Self.maximumDimension,
            0,
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_BYTE),
            nil
        )
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER),
            GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D),
            colorTexture,
            0
        )

        glGenRenderbuffers(1, &depthStencilBuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depthStencilBuffer)
        glRenderbufferStorage(
            GLenum(GL_RENDERBUFFER),
            GLenum(GL_DEPTH24_STENCIL8),
            Self.maximumDimension,
            Self.maximumDimension
        )
        glFramebufferRenderbuffer(
            GLenum(GL_FRAMEBUFFER),
            GLenum(GL_DEPTH_STENCIL_ATTACHMENT),
            GLenum(GL_RENDERBUFFER),
            depthStencilBuffer
        )

        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            CGLDestroyContext(context)
            return nil
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    deinit {
        guard makeCurrent() else {
            CGLDestroyContext(context)
            return
        }
        if depthStencilBuffer != 0 {
            glDeleteRenderbuffers(1, &depthStencilBuffer)
        }
        if colorTexture != 0 {
            glDeleteTextures(1, &colorTexture)
        }
        if framebuffer != 0 {
            glDeleteFramebuffers(1, &framebuffer)
        }
        CGLSetCurrentContext(nil)
        CGLDestroyContext(context)
    }

    func makeCurrent() -> Bool {
        CGLSetCurrentContext(context) == kCGLNoError
    }

    func currentFramebuffer() -> UInt {
        UInt(framebuffer)
    }

    func procAddress(_ name: UnsafePointer<CChar>?) -> RetroHardwareProc? {
        guard
            let name,
            let library = openGLLibrary,
            let address = dlsym(library, name)
        else {
            // A core that asks for an entry point and gets nothing back will
            // call through the null pointer on its first frame, so record
            // exactly which symbol was missing.
            if let name {
                OpenVaultLog.libretro.error(
                    """
                    Core requested an unavailable OpenGL entry point: \
                    \(String(cString: name), privacy: .public)
                    """
                )
            }
            return nil
        }
        return unsafeBitCast(address, to: RetroHardwareProc.self)
    }

    func capture(width: Int, height: Int) -> LibretroVideoFrame? {
        guard
            width > 0,
            height > 0,
            width <= Int(Self.maximumDimension),
            height <= Int(Self.maximumDimension),
            makeCurrent()
        else {
            return nil
        }

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFinish()
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)

        let bytesPerRow = width * 4
        var source = Data(count: bytesPerRow * height)
        source.withUnsafeMutableBytes {
            glReadPixels(
                0,
                0,
                GLsizei(width),
                GLsizei(height),
                GLenum(GL_BGRA),
                GLenum(GL_UNSIGNED_BYTE),
                $0.baseAddress
            )
        }

        var pixels = Data(count: source.count)
        source.withUnsafeBytes { sourceBytes in
            pixels.withUnsafeMutableBytes { destinationBytes in
                guard
                    let sourceBase = sourceBytes.baseAddress,
                    let destinationBase = destinationBytes.baseAddress
                else {
                    return
                }
                for row in 0 ..< height {
                    destinationBase
                        .advanced(by: row * bytesPerRow)
                        .copyMemory(
                            from: sourceBase.advanced(
                                by: (height - row - 1) * bytesPerRow
                            ),
                            byteCount: bytesPerRow
                        )
                }
            }
        }

        return LibretroVideoFrame(
            pixels: pixels,
            width: width,
            height: height
        )
    }
}

private final class LibretroCStringStore {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func store(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
}

enum LibretroCoreOptionPreferences {
    private static let values = [
        // DOSBox Pure's ARM64 dynamic recompiler allocates its code cache with
        // malloc and then tries to make it executable with mprotect. Hardened
        // macOS rejects that transition even when the app has the JIT
        // entitlement, so protected-mode games trap shortly after their
        // executable is selected. The interpreter is slower but reliable.
        "dosbox_pure_cpu_core": "normal",

        // GLideN64's framebuffer path can produce valid but entirely black
        // frames through macOS's deprecated OpenGL implementation. The
        // multithreaded Angrylion renderer is CPU-based, accurate, and avoids
        // that hardware-context compatibility boundary on Apple Silicon.
        "parallel-n64-gfxplugin": "angrylion",
        "parallel-n64-angrylion-multithread": "all threads",

        // ParaLLEl-N64 leaves every controller accessory slot empty by
        // default. Games that save to a Controller Pak therefore report that
        // no memory card is inserted even though the core exposes its mempak
        // bytes through RETRO_MEMORY_SAVE_RAM. Attach a Memory Pak to player
        // one so the existing save-memory persistence and RomM sync path can
        // preserve it.
        "parallel-n64-pak1": "memory",

        // The RSP runs the N64's audio microcode as well as its graphics
        // tasks, so the plugin chosen for video decides how audio is
        // produced. Pinning cxd4 put audio through instruction-level RSP
        // emulation, a far less travelled path than the high-level default,
        // and left it pitched up. Angrylion does not require cxd4, so the
        // core is left to choose.
        "parallel-n64-rspplugin": "auto",

        // Flycast defaults to running its GPU on a second thread. The runtime
        // owns one CGL context, and a CGL context can only be current on one
        // thread at a time, so the render thread would issue GL calls with no
        // context current at all. Keeping the GPU on the emulation thread,
        // where `makeCurrent` actually bound the context, costs speed and is
        // the only correct arrangement here.
        "reicast_threaded_rendering": "disabled",

        // A Dreamcast title that renders every second field presents at half
        // the field rate. Flycast only tells the frontend about that when
        // this is on; left off, it keeps reporting the full rate while
        // handing over one frame per call, and the frontend paces a 30 Hz
        // game at 60 Hz, running it at double speed.
        "reicast_detect_vsync_swap_interval": "enabled",
    ]

    /// Resolves the value to hand a core for `key`.
    ///
    /// The compatibility overrides above win outright: they exist because a
    /// core misbehaves on this stack without them, which is not something a
    /// preference should be able to undo. Everything else falls through to the
    /// internal-resolution preference, which can only pick from the values
    /// `availableValues` says the core will accept.
    static func value(
        for key: String,
        default defaultValue: String,
        availableValues: [String] = [],
        internalResolution: LibretroInternalResolution = .native
    ) -> String {
        if let override = values[key] {
            return override
        }
        if let resolutionValue = LibretroInternalResolutionOption.value(
            forKey: key,
            resolution: internalResolution,
            availableValues: availableValues
        ) {
            return resolutionValue
        }
        return defaultValue
    }
}

private final class LibretroEnvironment {
    private let strings = LibretroCStringStore()
    private let systemDirectory: UnsafePointer<CChar>
    private let saveDirectory: UnsafePointer<CChar>
    private let assetsDirectory: UnsafePointer<CChar>
    /// Read once when the session is built rather than per option, so a core
    /// cannot see the preference change midway through publishing its list.
    private let internalResolution: LibretroInternalResolution
    private var variables: [String: UnsafePointer<CChar>] = [:]
    private(set) var wantsKeyboard = false
    private(set) var keyboardEvent: RetroKeyboardEventCallback?
    private var hardwareRenderer: LibretroOpenGLRenderer?
    private var hardwareContextReset: RetroHardwareContextCallback?
    private var hardwareContextDestroy: RetroHardwareContextCallback?
    private var isHardwareContextActive = false

    private(set) var pixelFormat = LibretroABI.PixelFormat.zeroRGB1555
    /// Updated by SET_GEOMETRY and SET_SYSTEM_AV_INFO, which N64 cores use to
    /// change resolution mid-game without changing the picture's shape.
    private(set) var requestedAspectRatio: Float = 0
    /// The frame rate the core last asked to be paced at, or 0 while it is
    /// still content with the rate it reported at load.
    private(set) var requestedFramesPerSecond: Double = 0

    /// Takes the ratio from `retro_get_system_av_info` for cores that report
    /// it once at load. A core that already announced its own geometry keeps
    /// what it chose.
    func seedAspectRatio(_ aspectRatio: Float) {
        guard
            requestedAspectRatio == 0,
            aspectRatio.isFinite,
            aspectRatio > 0
        else {
            return
        }
        requestedAspectRatio = aspectRatio
    }
    private(set) var supportsNoGame = false
    private(set) var requestedShutdown = false

    init(
        systemDirectory: URL,
        saveDirectory: URL,
        assetsDirectory: URL,
        internalResolution: LibretroInternalResolution
    ) {
        self.systemDirectory = strings.store(systemDirectory.path)
        self.saveDirectory = strings.store(saveDirectory.path)
        self.assetsDirectory = strings.store(assetsDirectory.path)
        self.internalResolution = internalResolution
    }

    func handle(command rawCommand: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
        guard let command = LibretroABI.EnvironmentCommand(rawValue: rawCommand) else {
            return false
        }

        switch command {
        case .getCanDupe:
            data?.storeBytes(of: true, as: Bool.self)
            return data != nil
        case .setMessage:
            return true
        case .setKeyboardCallback:
            return captureKeyboardCallback(from: data)
        case .shutdown:
            requestedShutdown = true
            return true
        case .getSystemDirectory:
            return write(systemDirectory, to: data)
        case .setPixelFormat:
            guard let data else {
                return false
            }
            let rawFormat = data.load(as: Int32.self)
            guard let format = LibretroABI.PixelFormat(rawValue: rawFormat) else {
                return false
            }
            pixelFormat = format
            return true
        case .setInputDescriptors:
            return true
        case .setHardwareRender:
            return configureHardwareRenderer(from: data)
        case .getVariable:
            return readVariable(from: data)
        case .setVariables:
            return captureVariables(from: data)
        case .getVariableUpdate:
            data?.storeBytes(of: false, as: Bool.self)
            return data != nil
        case .setSupportNoGame:
            guard let data else {
                return false
            }
            supportsNoGame = data.load(as: Bool.self)
            return true
        case .setFrameTimeCallback:
            return true
        case .getLogInterface:
            guard let data else {
                return false
            }
            data.storeBytes(
                of: openVaultLibretroLogCallbackPointer(),
                as: UnsafeMutableRawPointer?.self
            )
            return true
        case .getCoreAssetsDirectory:
            return write(assetsDirectory, to: data)
        case .getSaveDirectory:
            return write(saveDirectory, to: data)
        case .setGeometry:
            // retro_game_geometry, whose aspect ratio sits after four
            // unsigned dimensions. It carries no timing, so nothing beyond
            // this structure may be read here.
            if let data {
                let aspectRatio = data.load(
                    fromByteOffset: 16,
                    as: Float.self
                )
                if aspectRatio.isFinite, aspectRatio > 0 {
                    requestedAspectRatio = aspectRatio
                }
            }
            return true
        case .setSystemAVInfo:
            // retro_system_av_info begins with the same geometry and then adds
            // retro_system_timing, whose frame rate is what separates this
            // command from SET_GEOMETRY. A core changes it when the emulated
            // machine changes how often it presents: a Dreamcast game running
            // its renderer every second field reports half the field rate, and
            // pacing it at the original rate would run the game at double
            // speed.
            if let data {
                let aspectRatio = data.load(
                    fromByteOffset: 16,
                    as: Float.self
                )
                if aspectRatio.isFinite, aspectRatio > 0 {
                    requestedAspectRatio = aspectRatio
                }
                let framesPerSecond = data.load(
                    fromByteOffset: 24,
                    as: Double.self
                )
                if framesPerSecond.isFinite, framesPerSecond > 0 {
                    requestedFramesPerSecond = framesPerSecond
                }
            }
            return true
        case .getLanguage:
            data?.storeBytes(of: UInt32(0), as: UInt32.self)
            return data != nil
        case .getCurrentSoftwareFramebuffer:
            return false
        case .getVFSInterface:
            return false
        case .getTargetRefreshRate:
            data?.storeBytes(of: Float(60), as: Float.self)
            return data != nil
        case .getInputBitmasks:
            return true
        case .getSensorInterface:
            guard let data else {
                return false
            }
            data.storeBytes(
                of: RetroSensorInterface(
                    setSensorState: libretroSetSensorStateCallback,
                    getSensorInput: libretroSensorInputCallback
                ),
                as: RetroSensorInterface.self
            )
            return true
        case .getPreferredHardwareRender:
            guard let data else {
                return false
            }
            data.storeBytes(
                of: LibretroABI.HardwareContext.openGLCore.rawValue,
                as: Int32.self
            )
            return true
        }
    }

    func makeHardwareContextCurrent() {
        _ = hardwareRenderer?.makeCurrent()
    }

    func currentHardwareFramebuffer() -> UInt {
        hardwareRenderer?.currentFramebuffer() ?? 0
    }

    func hardwareProcAddress(_ name: UnsafePointer<CChar>?) -> RetroHardwareProc? {
        hardwareRenderer?.procAddress(name)
    }

    func captureHardwareFrame(width: Int, height: Int) -> LibretroVideoFrame? {
        hardwareRenderer?.capture(width: width, height: height)
    }

    func destroyHardwareRenderer() {
        guard hardwareRenderer != nil else {
            return
        }
        makeHardwareContextCurrent()
        if isHardwareContextActive {
            hardwareContextDestroy?()
        }
        hardwareContextReset = nil
        hardwareContextDestroy = nil
        isHardwareContextActive = false
        hardwareRenderer = nil
    }

    func activateHardwareRenderer() -> Bool {
        guard let hardwareRenderer else {
            return true
        }
        guard hardwareRenderer.makeCurrent() else {
            return false
        }
        guard !isHardwareContextActive else {
            return true
        }

        hardwareContextReset?()
        isHardwareContextActive = true
        return true
    }

    private func configureHardwareRenderer(
        from data: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let data else {
            return false
        }
        let callback = data.assumingMemoryBound(
            to: RetroHardwareRenderCallback.self
        )
        guard
            callback.pointee.contextType
                == LibretroABI.HardwareContext.openGLCore.rawValue,
            callback.pointee.versionMajor <= 4,
            let renderer = hardwareRenderer
                ?? LibretroOpenGLRenderer(
                    majorVersion: callback.pointee.versionMajor
                )
        else {
            return false
        }

        hardwareRenderer = renderer
        hardwareContextReset = callback.pointee.contextReset
        hardwareContextDestroy = callback.pointee.contextDestroy
        callback.pointee.getCurrentFramebuffer =
            libretroHardwareFramebufferCallback
        callback.pointee.getProcAddress =
            libretroHardwareProcAddressCallback

        guard renderer.makeCurrent() else {
            hardwareContextReset = nil
            hardwareContextDestroy = nil
            hardwareRenderer = nil
            return false
        }
        return true
    }

    private func write(
        _ pointer: UnsafePointer<CChar>,
        to data: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let data else {
            return false
        }
        data.storeBytes(of: pointer, as: UnsafePointer<CChar>?.self)
        return true
    }

    /// Records a core's `retro_keyboard_callback`.
    ///
    /// A core registering one is the runtime's signal that it wants real keys
    /// rather than the RetroPad the other cores are driven with. DOSBox Pure
    /// registers one, which is what puts a DOS game in front of a full
    /// keyboard.
    private func captureKeyboardCallback(
        from data: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let data else {
            return false
        }
        keyboardEvent = data.load(as: RetroKeyboardEventCallback?.self)
        wantsKeyboard = true
        return true
    }

    private func captureVariables(from data: UnsafeMutableRawPointer?) -> Bool {
        guard let data else {
            return false
        }

        var index = 0
        while index < 1_024 {
            let offset = index * 16
            guard let keyPointer = data.load(
                fromByteOffset: offset,
                as: UnsafePointer<CChar>?.self
            ) else {
                break
            }
            let descriptionPointer = data.load(
                fromByteOffset: offset + 8,
                as: UnsafePointer<CChar>?.self
            )
            let key = String(cString: keyPointer)
            if let descriptionPointer {
                let description = String(cString: descriptionPointer)
                let values = description
                    .split(separator: ";", maxSplits: 1)
                    .dropFirst()
                    .first?
                    .split(separator: "|")
                    .map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                if let values, let defaultValue = values.first,
                   !defaultValue.isEmpty
                {
                    let resolved = LibretroCoreOptionPreferences.value(
                        for: key,
                        default: defaultValue,
                        availableValues: values,
                        internalResolution: internalResolution
                    )
                    if
                        resolved != defaultValue,
                        LibretroInternalResolutionOption.isResolutionKey(key)
                    {
                        OpenVaultLog.libretro.info(
                            """
                            Internal resolution: set \(key, privacy: .public) \
                            to \(resolved, privacy: .public)
                            """
                        )
                    }
                    variables[key] = strings.store(resolved)
                }
            }
            index += 1
        }
        return true
    }

    private func readVariable(from data: UnsafeMutableRawPointer?) -> Bool {
        guard
            let data,
            let keyPointer = data.load(as: UnsafePointer<CChar>?.self)
        else {
            return false
        }

        let key = String(cString: keyPointer)
        data.storeBytes(
            of: variables[key],
            toByteOffset: 8,
            as: UnsafePointer<CChar>?.self
        )
        return variables[key] != nil
    }
}

private final class LibretroEngine: @unchecked Sendable, LibretroCallbackTarget {
    enum Event: Sendable {
        case running(coreName: String, framesPerSecond: Double)
        case stopped
        case failed(String)
        case controllerExitRequested
        case quickStateSaved
        case quickStateLoaded
        case notice(String)
        case saveMemoryPersisted
        case rewindAvailabilityChanged(Bool)
        case rewound(canContinue: Bool)
    }

    private enum Command {
        case reset
        case setMuted(Bool)
        case saveQuickState
        case saveQuickStateAndStop
        case loadQuickState
        case rewind(steps: Int)
    }

    private static let rewindByteLimit = 128 * 1_024 * 1_024
    private static let rewindEntryLimit =
        LibretroRewindCadence.maximumEntryCount
    private static let heldRewindMultiplier = 2
    private static let fastForwardMultiplier = 4.0

    private struct Paths {
        let system: URL
        let saves: URL
        let legacySaves: URL?
        let states: URL
        let assets: URL
    }

    let hasQuickState: Bool

    private let request: LibretroRunRequest
    private let videoBuffer: LibretroVideoBuffer
    private let inputState: LibretroInputState
    private let audioOutput = LibretroAudioOutput()
    private let queue = DispatchQueue(
        label: "org.kennethreitz.OpenVault.libretro",
        qos: .userInteractive
    )
    private let controlLock = NSLock()
    private let paths: Paths
    private let quickStateURL: URL
    private let quickStateFingerprintURL: URL
    private let coreFingerprint: String?
    private let saveMemoryURL: URL
    private let installationOverride: LibretroInstallation?

    private var environment: LibretroEnvironment?
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var commands: [Command] = []
    private var isActive = false
    private var shouldStop = false
    private var isPaused = false

    init(
        request: LibretroRunRequest,
        videoBuffer: LibretroVideoBuffer,
        input: LibretroInputState,
        installation: LibretroInstallation? = nil
    ) {
        self.request = request
        self.videoBuffer = videoBuffer
        inputState = input
        installationOverride = installation

        let paths = Self.paths(for: request)
        self.paths = paths
        quickStateURL = paths.states.appending(path: "Quick.state")
        quickStateFingerprintURL = paths.states.appending(
            path: LibretroQuickStateCompatibility.fingerprintFileName
        )
        coreFingerprint = Self.coreFingerprint(
            request: request,
            installation: installation
        )
        if
            let saveSync = request.saveSync,
            saveSync.effectiveStorage == .saveRAM
        {
            saveMemoryURL = saveSync.localSaveURL
        } else {
            saveMemoryURL = paths.saves.appending(path: "SaveRAM.srm")
        }
        hasQuickState =
            FileManager.default.fileExists(atPath: quickStateURL.path)
            && LibretroQuickStateCompatibility.isCompatible(
                coreID: request.coreID,
                expectedFingerprint: coreFingerprint,
                storedFingerprint: try? String(
                    contentsOf: quickStateFingerprintURL,
                    encoding: .utf8
                )
            )
    }

    func start(eventHandler: @escaping @Sendable (Event) -> Void) {
        controlLock.lock()
        guard !isActive else {
            controlLock.unlock()
            eventHandler(.failed(LibretroRuntimeError.alreadyRunning.localizedDescription))
            return
        }
        isActive = true
        shouldStop = false
        isPaused = false
        commands.removeAll()
        self.eventHandler = eventHandler
        controlLock.unlock()

        queue.async { [self] in
            runLoop()
        }
    }

    func setPaused(_ paused: Bool) {
        controlLock.lock()
        isPaused = paused
        controlLock.unlock()
    }

    func reset() {
        enqueue(.reset)
    }

    func setMuted(_ isMuted: Bool) {
        enqueue(.setMuted(isMuted))
    }

    func saveQuickState() {
        enqueue(.saveQuickState)
    }

    func saveQuickStateAndStop() {
        enqueue(.saveQuickStateAndStop)
    }

    func loadQuickState() {
        enqueue(.loadQuickState)
    }

    func rewind() {
        enqueue(.rewind(steps: 1))
    }

    func stop() {
        controlLock.lock()
        shouldStop = true
        controlLock.unlock()
    }

    func environment(command: UInt32, data: UnsafeMutableRawPointer?) -> Bool {
        environment?.handle(command: command, data: data) ?? false
    }

    func video(data: UnsafeRawPointer?, width: UInt32, height: UInt32, pitch: Int) {
        guard let data else {
            return
        }

        if UInt(bitPattern: data) == UInt.max {
            guard
                let frame = environment?.captureHardwareFrame(
                    width: Int(width),
                    height: Int(height)
                )
            else {
                stop()
                emit(
                    .failed(
                        "The hardware-rendered frame could not be read from the core."
                    )
                )
                return
            }
            videoBuffer.publish(stamped(frame))
            return
        }

        do {
            let frame = try Self.videoFrame(
                data: data,
                width: Int(width),
                height: Int(height),
                pitch: pitch,
                format: environment?.pixelFormat ?? .zeroRGB1555
            )
            videoBuffer.publish(stamped(frame))
        } catch {
            stop()
            emit(.failed(error.localizedDescription))
        }
    }

    func audio(left: Int16, right: Int16) {
        audioOutput.append(left: left, right: right)
    }

    func audio(data: UnsafePointer<Int16>?, frames: Int) -> Int {
        audioOutput.append(samples: data, frames: frames)
        return frames
    }

    func pollInput() {
        inputState.pollController()
        deliverKeyEvents()
        if inputState.consumeExitRequest() {
            emit(.controllerExitRequested)
        }
    }

    /// Passes queued key presses to the core's keyboard callback.
    ///
    /// Called from `pollInput`, so the core is re-entered on the emulation
    /// thread at the point in the frame it expects input, rather than from
    /// whichever thread AppKit delivered the key on.
    private func deliverKeyEvents() {
        guard let keyboardEvent = environment?.keyboardEvent else {
            return
        }
        for event in inputState.drainKeyEvents() {
            keyboardEvent(
                event.pressed,
                event.key,
                // The character a key produces is layout-dependent and
                // nothing bundled reads it; the keycode carries the meaning.
                0,
                event.modifiers
            )
        }
    }

    func input(
        port: UInt32,
        device: UInt32,
        index: UInt32,
        id: UInt32
    ) -> Int16 {
        guard port < 2 else {
            return 0
        }

        switch device & 0xFF {
        case LibretroABI.joypadDevice:
            return index == 0
                ? inputState.value(for: id, port: port)
                : 0
        case LibretroABI.analogDevice:
            return inputState.analogValue(
                index: index,
                id: id,
                port: port
            )
        case LibretroABI.pointerDevice:
            return port == 0 && index == 0
                ? inputState.pointerValue(for: id)
                : 0
        case LibretroKeyboard.device:
            return port == 0 ? inputState.keyValue(for: id) : 0
        default:
            return 0
        }
    }

    /// Records the display shape alongside the pixels, so a core that changes
    /// resolution mid-game keeps the picture it asked for.
    private func stamped(_ frame: LibretroVideoFrame) -> LibretroVideoFrame {
        var frame = frame
        frame.aspectRatio = environment?.requestedAspectRatio ?? 0
        return frame
    }

    func setSensorState(port: UInt32, action rawAction: UInt32, rate: UInt32) -> Bool {
        guard
            port == 0,
            let action = LibretroABI.SensorAction(rawValue: rawAction)
        else {
            return false
        }

        switch action {
        case .enableAccelerometer:
            inputState.setSensorEnabled(true, accelerometer: true)
        case .disableAccelerometer:
            inputState.setSensorEnabled(false, accelerometer: true)
        case .enableGyroscope:
            inputState.setSensorEnabled(true, accelerometer: false)
        case .disableGyroscope:
            inputState.setSensorEnabled(false, accelerometer: false)
        }

        OpenVaultLog.libretro.info(
            """
            Core sensor request \(String(describing: action), privacy: .public) \
            at \(rate, privacy: .public) Hz
            """
        )
        return true
    }

    func sensorInput(port: UInt32, id: UInt32) -> Float {
        port == 0 ? inputState.sensorValue(for: id) : 0
    }

    func currentHardwareFramebuffer() -> UInt {
        environment?.currentHardwareFramebuffer() ?? 0
    }

    func hardwareProcAddress(
        _ name: UnsafePointer<CChar>?
    ) -> RetroHardwareProc? {
        environment?.hardwareProcAddress(name)
    }

    private func runLoop() {
        var core: LibretroCore?
        var initialized = false
        var loaded = false
        var failed = false
        var stagedContent: LibretroStagedContent?
        var rewindBuffer = LibretroRewindBuffer(
            byteLimit: Self.rewindByteLimit,
            entryLimit: Self.rewindEntryLimit
        )
        var rewindIsSupported = request.allowsRewind
        var rewindSnapshotInterval = 1.0 / 60.0

        defer {
            if loaded, let core {
                environment?.makeHardwareContextCurrent()
                if persistSaveMemory(from: core) {
                    emit(.saveMemoryPersisted)
                }
                environment?.destroyHardwareRenderer()
                core.unloadGame()
            } else {
                environment?.destroyHardwareRenderer()
            }
            if initialized {
                core?.deinitialize()
            }
            audioOutput.stop()
            LibretroCallbackRouter.shared.remove(self)
            environment = nil

            controlLock.lock()
            isActive = false
            let handler = eventHandler
            eventHandler = nil
            controlLock.unlock()

            if !failed {
                handler?(.stopped)
            }
        }

        do {
            try prepareDirectories()
            let installation =
                try installationOverride ?? LibretroInstallation.bundled()
            let (manifestCore, binaryURL) = try installation.core(id: request.coreID)

            guard LibretroCallbackRouter.shared.install(self) else {
                throw LibretroRuntimeError.alreadyRunning
            }

            let runtimeEnvironment = LibretroEnvironment(
                systemDirectory: paths.system,
                saveDirectory: paths.saves,
                assetsDirectory: paths.assets,
                internalResolution:
                    LibretroInternalResolutionPreferences.resolution()
            )
            environment = runtimeEnvironment

            let loadedCore = try LibretroCore(url: binaryURL)
            core = loadedCore
            loadedCore.installCallbacks()
            let systemInfo = try loadedCore.systemInfo()
            loadedCore.initialize()
            initialized = true
            stagedContent = try LibretroStagedContent.prepare(
                contentURL: request.contentURL,
                needsFullPath: systemInfo.needsFullPath
            )
            try loadedCore.loadGame(
                contentURL: stagedContent?.contentURL,
                needsFullPath: systemInfo.needsFullPath
            )
            loaded = true

            guard runtimeEnvironment.activateHardwareRenderer() else {
                throw LibretroRuntimeError.couldNotInitializeHardwareContext
            }
            // Cores that emulate real port hardware bind their input only when
            // the frontend declares what is plugged in, and the device a port
            // accepts can depend on the loaded title.
            let controllerDevice = LibretroControllerDevice.primaryDevice(
                coreID: request.coreID,
                systemName: request.systemName
            )
            inputState.setMapsLeftAnalogToDPad(
                LibretroAnalogToDPadPolicy.applies(
                    coreID: request.coreID,
                    controllerDevice: controllerDevice
                )
            )
            for port in UInt32(0)..<2 {
                loadedCore.setControllerPortDevice(
                    port: port,
                    device: controllerDevice
                )
            }
            // A core that registered a keyboard callback while loading wants
            // real keys, so hand it the whole keyboard instead of the RetroPad
            // shortcuts the keyboard otherwise stands in for.
            inputState.setKeyboardEnabled(runtimeEnvironment.wantsKeyboard)
            let avInfo = try loadedCore.avInfo()
            runtimeEnvironment.seedAspectRatio(avInfo.aspectRatio)
            try audioOutput.configure(sampleRate: avInfo.sampleRate)
            restoreSaveMemory(into: loadedCore)
            runtimeEnvironment.makeHardwareContextCurrent()
            let quickStateUpdatedAt = try? quickStateURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let restoresQuickState =
                hasQuickState
                && LibretroQuickStateRestorePolicy.shouldRestore(
                    requestAllowsRestore:
                        request.restoresQuickStateOnLaunch,
                    remoteSaveUpdatedAt:
                        request.saveSync?.remoteSaveUpdatedAt,
                    quickStateUpdatedAt: quickStateUpdatedAt
                )
            if
                request.restoresQuickStateOnLaunch,
                FileManager.default.fileExists(atPath: quickStateURL.path),
                !hasQuickState
            {
                OpenVaultLog.libretro.notice(
                    "Skipped a FAKE-08 quick state created by an incompatible core build"
                )
            } else if
                request.restoresQuickStateOnLaunch,
                !restoresQuickState
            {
                OpenVaultLog.libretro.notice(
                    "Skipped an older local quick state because RomM has a newer cartridge save"
                )
            }
            let quickStateRestore =
                restoresQuickState
                ? restoreQuickStateIfAvailable(into: loadedCore)
                : .notFound
            emit(
                .running(
                    coreName: "\(manifestCore.displayName) · \(systemInfo.name) \(systemInfo.version)",
                    framesPerSecond: avInfo.framesPerSecond
                )
            )
            switch quickStateRestore {
            case .notFound:
                break
            case .restored:
                emit(.quickStateLoaded)
                OpenVaultLog.libretro.notice(
                    "Restored the local quick state before starting gameplay"
                )
            case let .failed(message):
                emit(
                    .notice(
                        "OpenVault could not restore the previous session. Starting from the beginning."
                    )
                )
                OpenVaultLog.libretro.error(
                    "Could not restore the local quick state: \(message, privacy: .public)"
                )
            }

            var pacedFramesPerSecond = avInfo.framesPerSecond
            var frameDuration = 1 / pacedFramesPerSecond
            let rewindCadence = LibretroRewindCadence(
                framesPerSecond: avInfo.framesPerSecond,
                byteLimit: Self.rewindByteLimit
            )
            rewindSnapshotInterval =
                rewindCadence.initialSnapshotInterval
            var rewindCaptureSchedule = LibretroRewindCaptureSchedule(
                framesPerSecond: avInfo.framesPerSecond
            )
            var nextFrame = ProcessInfo.processInfo.systemUptime
            var wasFastForwarding = false
            var wasRewinding = false
            var isHoldingAtRewindBoundary = false

            while !stopRequested {
                // A core may change its frame rate mid-game through
                // SET_SYSTEM_AV_INFO. Pacing keeps using the rate reported at
                // load until it does, and follows it from then on.
                let requestedFramesPerSecond =
                    runtimeEnvironment.requestedFramesPerSecond
                if
                    requestedFramesPerSecond > 0,
                    requestedFramesPerSecond != pacedFramesPerSecond
                {
                    OpenVaultLog.libretro.info(
                        """
                        Core changed its frame rate from \
                        \(pacedFramesPerSecond, privacy: .public) to \
                        \(requestedFramesPerSecond, privacy: .public) FPS
                        """
                    )
                    pacedFramesPerSecond = requestedFramesPerSecond
                    frameDuration = 1 / pacedFramesPerSecond
                    nextFrame = ProcessInfo.processInfo.systemUptime
                }

                // Once history is exhausted the core cannot run merely to
                // discover that L3 was released: doing so advances the game
                // away from the oldest frame. Poll the physical controller
                // directly while held at the boundary instead.
                if isHoldingAtRewindBoundary {
                    inputState.pollController()
                }
                let transportControls =
                    inputState.currentTransportControls()
                let now = ProcessInfo.processInfo.systemUptime
                // Rewinding suspends `run()` so the loop can step backwards
                // through history instead of forwards. A core with no history
                // to offer must therefore never enter the rewinding state, or
                // holding the button would stall gameplay rather than do
                // nothing.
                let isRewinding =
                    transportControls.isRewinding && rewindIsSupported
                if isHoldingAtRewindBoundary, !isRewinding {
                    isHoldingAtRewindBoundary = false
                }
                if isRewinding, !isHoldingAtRewindBoundary {
                    enqueue(
                        .rewind(steps: Self.heldRewindMultiplier)
                    )
                }

                if
                    transportControls.isFastForwarding
                        != wasFastForwarding
                        || isRewinding != wasRewinding
                {
                    wasFastForwarding =
                        transportControls.isFastForwarding
                    wasRewinding = isRewinding
                    audioOutput.setTransportAudioSuppressed(
                        wasFastForwarding || wasRewinding
                    )
                    nextFrame = now
                }

                let didRewind = processCommands(
                    using: loadedCore,
                    rewindBuffer: &rewindBuffer,
                    rewindIsSupported: &rewindIsSupported,
                    rewindCaptureSchedule: &rewindCaptureSchedule
                )
                if didRewind, rewindBuffer.isEmpty, isRewinding {
                    isHoldingAtRewindBoundary = true
                }

                if paused {
                    if didRewind {
                        runtimeEnvironment.makeHardwareContextCurrent()
                        loadedCore.run()
                        audioOutput.flush()
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                    nextFrame = ProcessInfo.processInfo.systemUptime
                    continue
                }

                // Render the frame that first reaches the boundary, then hold
                // it without advancing until the direct controller poll above
                // observes L3 being released.
                if
                    isHoldingAtRewindBoundary,
                    isRewinding,
                    !didRewind
                {
                    Thread.sleep(forTimeInterval: 0.01)
                    nextFrame = ProcessInfo.processInfo.systemUptime
                    continue
                }
                runtimeEnvironment.makeHardwareContextCurrent()
                loadedCore.run()
                if !didRewind, !wasRewinding {
                    captureRewindStateIfNeeded(
                        using: loadedCore,
                        cadence: rewindCadence,
                        rewindBuffer: &rewindBuffer,
                        rewindIsSupported: &rewindIsSupported,
                        rewindCaptureSchedule: &rewindCaptureSchedule,
                        rewindSnapshotInterval: &rewindSnapshotInterval
                    )
                }
                if runtimeEnvironment.requestedShutdown {
                    stop()
                }

                let activeFrameDuration =
                    wasRewinding
                    ? rewindSnapshotInterval
                    : wasFastForwarding
                    ? frameDuration / Self.fastForwardMultiplier
                    : frameDuration
                nextFrame += activeFrameDuration
                let frameFinishedAt =
                    ProcessInfo.processInfo.systemUptime
                if nextFrame > frameFinishedAt {
                    Thread.sleep(
                        forTimeInterval: nextFrame - frameFinishedAt
                    )
                } else if frameFinishedAt - nextFrame > 0.25 {
                    nextFrame = frameFinishedAt
                }
            }
        } catch {
            failed = true
            emit(.failed(error.localizedDescription))
        }
    }

    private func enqueue(_ command: Command) {
        controlLock.lock()
        if isActive {
            commands.append(command)
        }
        controlLock.unlock()
    }

    private var stopRequested: Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        return shouldStop
    }

    private var paused: Bool {
        controlLock.lock()
        defer { controlLock.unlock() }
        return isPaused
    }

    private func processCommands(
        using core: LibretroCore,
        rewindBuffer: inout LibretroRewindBuffer,
        rewindIsSupported: inout Bool,
        rewindCaptureSchedule: inout LibretroRewindCaptureSchedule
    ) -> Bool {
        controlLock.lock()
        let pending = commands
        commands.removeAll()
        controlLock.unlock()

        var didRewind = false
        for command in pending {
            do {
                switch command {
                case .reset:
                    core.reset()
                    rewindBuffer.removeAll()
                    rewindIsSupported = request.allowsRewind
                    rewindCaptureSchedule.reset()
                    emit(.rewindAvailabilityChanged(false))
                case let .setMuted(isMuted):
                    audioOutput.setUserMuted(isMuted)
                case .saveQuickState:
                    try persistQuickState(using: core)
                case .saveQuickStateAndStop:
                    defer {
                        stop()
                    }
                    try persistQuickState(using: core)
                case .loadQuickState:
                    guard FileManager.default.fileExists(atPath: quickStateURL.path) else {
                        throw LibretroRuntimeError.stateUnavailable
                    }
                    let data = try Data(contentsOf: quickStateURL)
                    try core.loadState(data)
                    rewindBuffer.removeAll()
                    rewindIsSupported = request.allowsRewind
                    rewindCaptureSchedule.reset()
                    audioOutput.flush()
                    emit(.rewindAvailabilityChanged(false))
                    emit(.quickStateLoaded)
                case let .rewind(steps):
                    guard rewindIsSupported else {
                        continue
                    }
                    guard
                        let state = rewindBuffer.popLast(steps: steps)
                    else {
                        continue
                    }
                    try core.loadState(state)
                    audioOutput.discardPendingSamples()
                    rewindCaptureSchedule.reset()
                    didRewind = true
                    if rewindBuffer.isEmpty {
                        emit(.rewound(canContinue: false))
                    }
                }
            } catch {
                emit(.notice(error.localizedDescription))
            }
        }
        return didRewind
    }

    private func persistQuickState(using core: LibretroCore) throws {
        let data = try core.saveState()
        try data.write(to: quickStateURL, options: .atomic)
        if let coreFingerprint {
            try coreFingerprint.write(
                to: quickStateFingerprintURL,
                atomically: true,
                encoding: .utf8
            )
        }
        emit(.quickStateSaved)
    }

    private func captureRewindStateIfNeeded(
        using core: LibretroCore,
        cadence: LibretroRewindCadence,
        rewindBuffer: inout LibretroRewindBuffer,
        rewindIsSupported: inout Bool,
        rewindCaptureSchedule: inout LibretroRewindCaptureSchedule,
        rewindSnapshotInterval: inout TimeInterval
    ) {
        guard rewindIsSupported, rewindCaptureSchedule.shouldCapture() else {
            return
        }

        do {
            let wasEmpty = rewindBuffer.isEmpty
            let state = try core.saveState()
            guard cadence.canSustainRewind(forStateByteCount: state.count) else {
                rewindIsSupported = false
                rewindBuffer.removeAll()
                emit(.rewindAvailabilityChanged(false))
                emit(
                    .notice(
                        "Rewind is unavailable because this core’s states are too large to keep a useful history."
                    )
                )
                OpenVaultLog.libretro.notice(
                    "Disabled rewind: \(state.count, privacy: .public) byte states cannot sustain \(Int(LibretroRewindCadence.targetHistoryDuration), privacy: .public) seconds of history within the \(Self.rewindByteLimit, privacy: .public) byte budget"
                )
                return
            }
            rewindSnapshotInterval =
                cadence.snapshotInterval(forStateByteCount: state.count)
            rewindCaptureSchedule.didCapture(
                snapshotInterval: rewindSnapshotInterval
            )
            guard rewindBuffer.append(state) else {
                rewindIsSupported = false
                emit(.rewindAvailabilityChanged(false))
                emit(
                    .notice(
                        "Rewind is unavailable because this core’s state exceeds the 128 MB history limit."
                    )
                )
                return
            }
            if wasEmpty {
                emit(.rewindAvailabilityChanged(true))
            }
        } catch {
            rewindIsSupported = false
            rewindBuffer.removeAll()
            emit(.rewindAvailabilityChanged(false))
            OpenVaultLog.libretro.info(
                "Rewind is unavailable for this core: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func restoreSaveMemory(into core: LibretroCore) {
        guard
            let (destination, size) = core.saveMemory(),
            let data = try? Data(contentsOf: saveMemoryURL),
            data.count == size
        else {
            return
        }
        data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: size)
    }

    private enum QuickStateRestore {
        case notFound
        case restored
        case failed(String)
    }

    private func restoreQuickStateIfAvailable(
        into core: LibretroCore
    ) -> QuickStateRestore {
        guard FileManager.default.fileExists(atPath: quickStateURL.path) else {
            return .notFound
        }

        do {
            let data = try Data(contentsOf: quickStateURL)
            try core.loadState(data)
            audioOutput.flush()
            return .restored
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func persistSaveMemory(from core: LibretroCore) -> Bool {
        guard let (source, size) = core.saveMemory() else {
            return false
        }
        let data = Data(bytes: source, count: size)
        do {
            try data.write(to: saveMemoryURL, options: .atomic)
            return true
        } catch {
            emit(.notice("OpenVault could not save battery-backed memory: \(error.localizedDescription)"))
            return false
        }
    }

    private func prepareDirectories() throws {
        if
            let legacySaves = paths.legacySaves,
            !FileManager.default.fileExists(atPath: paths.saves.path),
            FileManager.default.fileExists(atPath: legacySaves.path)
        {
            try FileManager.default.createDirectory(
                at: paths.saves.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: legacySaves,
                to: paths.saves
            )
            OpenVaultLog.libretro.notice(
                "Migrated this core's existing directory-based save into managed sync storage"
            )
        }

        for directory in [
            paths.system,
            paths.saves,
            paths.states,
            paths.assets,
            saveMemoryURL.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func emit(_ event: Event) {
        controlLock.lock()
        let handler = eventHandler
        controlLock.unlock()
        handler?(event)
    }

    private static func paths(for request: LibretroRunRequest) -> Paths {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.homeDirectory
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let safeCoreID = request.coreID.replacingOccurrences(of: "/", with: "-")
        let contentKey = LibretroContentIdentity.key(
            for: request.contentURL
        )
        let root = applicationSupport
            .appending(path: "OpenVault", directoryHint: .isDirectory)
            .appending(path: "Libretro", directoryHint: .isDirectory)
            .appending(path: safeCoreID, directoryHint: .isDirectory)
            .appending(path: contentKey, directoryHint: .isDirectory)
        let bundledSystemDirectory = Bundle.main.resourceURL?
            .appending(path: "Libretro", directoryHint: .isDirectory)
            .appending(path: "System", directoryHint: .isDirectory)
        let readableBundledSystemDirectory = bundledSystemDirectory.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }

        let coreSaveDirectory: URL
        let legacySaveDirectory: URL?
        if
            let saveSync = request.saveSync,
            saveSync.effectiveStorage == .directoryBundle
        {
            coreSaveDirectory = saveSync.localSaveURL
            legacySaveDirectory = root.appending(
                path: "Saves",
                directoryHint: .isDirectory
            )
        } else {
            coreSaveDirectory = root.appending(
                path: "Saves",
                directoryHint: .isDirectory
            )
            legacySaveDirectory = nil
        }

        return Paths(
            system: request.systemDirectory
                ?? readableBundledSystemDirectory
                ?? root.appending(path: "System", directoryHint: .isDirectory),
            saves: coreSaveDirectory,
            legacySaves: legacySaveDirectory,
            states: root.appending(path: "States", directoryHint: .isDirectory),
            assets: root.appending(path: "Assets", directoryHint: .isDirectory)
        )
    }

    private static func coreFingerprint(
        request: LibretroRunRequest,
        installation: LibretroInstallation?
    ) -> String? {
        guard
            LibretroQuickStateCompatibility.requiresCoreFingerprint(
                coreID: request.coreID
            )
        else {
            return nil
        }
        do {
            let resolvedInstallation =
                try installation ?? LibretroInstallation.bundled()
            let (_, binaryURL) = try resolvedInstallation.core(
                id: request.coreID
            )
            return try LibretroQuickStateCompatibility.coreFingerprint(
                binaryURL: binaryURL
            )
        } catch {
            OpenVaultLog.libretro.error(
                "Could not fingerprint \(request.coreID, privacy: .public) for quick-state compatibility: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func videoFrame(
        data: UnsafeRawPointer,
        width: Int,
        height: Int,
        pitch: Int,
        format: LibretroABI.PixelFormat
    ) throws -> LibretroVideoFrame {
        guard width > 0, height > 0, pitch > 0 else {
            throw LibretroRuntimeError.invalidSystemInformation
        }

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.baseAddress?
                .assumingMemoryBound(to: UInt8.self)
            else {
                return
            }

            for y in 0 ..< height {
                let sourceRow = data
                    .advanced(by: y * pitch)
                    .assumingMemoryBound(to: UInt8.self)
                let destinationRow = destination.advanced(by: y * width * 4)

                switch format {
                case .xRGB8888:
                    for x in 0 ..< width {
                        destinationRow[x * 4] = sourceRow[x * 4]
                        destinationRow[x * 4 + 1] = sourceRow[x * 4 + 1]
                        destinationRow[x * 4 + 2] = sourceRow[x * 4 + 2]
                        destinationRow[x * 4 + 3] = 255
                    }
                case .rgb565:
                    let source = UnsafeRawPointer(sourceRow)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0 ..< width {
                        let value = UInt16(littleEndian: source[x])
                        destinationRow[x * 4] = UInt8((value & 0x1F) * 255 / 31)
                        destinationRow[x * 4 + 1] = UInt8(((value >> 5) & 0x3F) * 255 / 63)
                        destinationRow[x * 4 + 2] = UInt8(((value >> 11) & 0x1F) * 255 / 31)
                        destinationRow[x * 4 + 3] = 255
                    }
                case .zeroRGB1555:
                    let source = UnsafeRawPointer(sourceRow)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0 ..< width {
                        let value = UInt16(littleEndian: source[x])
                        destinationRow[x * 4] = UInt8((value & 0x1F) * 255 / 31)
                        destinationRow[x * 4 + 1] = UInt8(((value >> 5) & 0x1F) * 255 / 31)
                        destinationRow[x * 4 + 2] = UInt8(((value >> 10) & 0x1F) * 255 / 31)
                        destinationRow[x * 4 + 3] = 255
                    }
                }
            }
        }

        return LibretroVideoFrame(pixels: pixels, width: width, height: height)
    }
}
