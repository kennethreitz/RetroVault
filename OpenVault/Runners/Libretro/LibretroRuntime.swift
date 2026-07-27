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
    let systemDirectory: URL?
    let saveSync: CartridgeSaveSyncConfiguration?
    let playerOrigin: LibretroPlayerOrigin?
    let skipsQuickStateRestore: Bool?

    init(
        title: String,
        coreID: String,
        contentURL: URL?,
        systemDirectory: URL? = nil,
        saveSync: CartridgeSaveSyncConfiguration? = nil,
        playerOrigin: LibretroPlayerOrigin? = nil,
        skipsQuickStateRestore: Bool? = nil
    ) {
        self.title = title
        self.coreID = coreID
        self.contentURL = contentURL
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

enum LibretroRewindPolicy {
    static func isEnabled(forCoreID coreID: String) -> Bool {
        let normalizedCoreID = coreID.lowercased()
        return !normalizedCoreID.contains("n64")
            && !normalizedCoreID.contains("mupen64")
    }
}

struct LibretroVideoFrame: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
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

    func publish(_ frame: LibretroVideoFrame) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    func snapshot() -> LibretroVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

final class LibretroInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var keyboardButtons: UInt16 = 0
    private var pendingKeyboardPresses: UInt16 = 0
    private var controllerButtons: UInt16 = 0
    private var polledButtons: UInt16 = 0
    private var leftAnalogX: Int16 = 0
    private var leftAnalogY: Int16 = 0
    private var rightAnalogX: Int16 = 0
    private var rightAnalogY: Int16 = 0
    private var pointerX: Int16 = 0
    private var pointerY: Int16 = 0
    private var pointerPressed = false
    private var pointerInside = false
    private var exitChord = LibretroControllerExitChord()
    private var exitRequested = false

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

    func releaseKeyboard() {
        lock.lock()
        keyboardButtons = 0
        pendingKeyboardPresses = 0
        polledButtons = controllerButtons
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
        let controllers = GCController.controllers()
        guard
            let controller = GCController.current ?? controllers.first,
            let gamepad = controller.extendedGamepad
        else {
            lock.lock()
            _ = exitChord.update(startPressed: false, selectPressed: false)
            controllerButtons = 0
            polledButtons = keyboardButtons | pendingKeyboardPresses
            leftAnalogX = digitalAxis(
                negative: polledButtons & LibretroButton.left.mask != 0,
                positive: polledButtons & LibretroButton.right.mask != 0
            )
            leftAnalogY = digitalAxis(
                negative: polledButtons & LibretroButton.up.mask != 0,
                positive: polledButtons & LibretroButton.down.mask != 0
            )
            rightAnalogX = 0
            rightAnalogY = 0
            pendingKeyboardPresses = 0
            lock.unlock()
            return
        }

        var buttons: UInt16 = 0
        buttons.set(.up, when: gamepad.dpad.up.isPressed)
        buttons.set(.down, when: gamepad.dpad.down.isPressed)
        buttons.set(.left, when: gamepad.dpad.left.isPressed)
        buttons.set(.right, when: gamepad.dpad.right.isPressed)
        buttons |= Self.faceButtonMask(
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
        let selectPressed = gamepad.buttonOptions?.isPressed == true
        let startPressed = gamepad.buttonMenu.isPressed

        lock.lock()
        let isExitChordPressed = startPressed && selectPressed
        if exitChord.update(
            startPressed: startPressed,
            selectPressed: selectPressed
        ) {
            exitRequested = true
        }
        if !isExitChordPressed {
            buttons.set(.select, when: selectPressed)
            buttons.set(.start, when: startPressed)
        }
        controllerButtons = buttons
        polledButtons = keyboardButtons | pendingKeyboardPresses | controllerButtons
        leftAnalogX = analogAxis(gamepad.leftThumbstick.xAxis.value)
        leftAnalogY = analogAxis(-gamepad.leftThumbstick.yAxis.value)
        rightAnalogX = analogAxis(gamepad.rightThumbstick.xAxis.value)
        rightAnalogY = analogAxis(-gamepad.rightThumbstick.yAxis.value)
        pendingKeyboardPresses = 0
        lock.unlock()
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

    func consumeExitRequest() -> Bool {
        lock.lock()
        defer {
            exitRequested = false
            lock.unlock()
        }
        return exitRequested
    }

    func value(for id: UInt32) -> Int16 {
        lock.lock()
        let buttons = polledButtons
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

    func analogValue(index: UInt32, id: UInt32) -> Int16 {
        lock.lock()
        defer { lock.unlock() }

        return switch (index, id) {
        case (LibretroABI.analogLeftIndex, LibretroABI.analogXID):
            leftAnalogX
        case (LibretroABI.analogLeftIndex, LibretroABI.analogYID):
            leftAnalogY
        case (LibretroABI.analogRightIndex, LibretroABI.analogXID):
            rightAnalogX
        case (LibretroABI.analogRightIndex, LibretroABI.analogYID):
            rightAnalogY
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

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
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
            OpenVaultLog.libretro.notice(
                "Core \(coreName, privacy: .public) is running at \(framesPerSecond, privacy: .public) FPS"
            )
        case .stopped:
            phase = .stopped
            isPaused = false
            canRewind = false
            if request.saveSync != nil, saveSyncPhase == .idle {
                synchronizeCartridgeSave()
            }
            OpenVaultLog.libretro.notice("Libretro session stopped")
        case let .failed(error):
            phase = .failed(error)
            isPaused = false
            canRewind = false
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
    static let joypadDevice: UInt32 = 1
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
    static let saveRAM: UInt32 = 0

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
private typealias RetroInputStateCallback =
    @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16
private typealias RetroHardwareContextCallback =
    @convention(c) () -> Void
private typealias RetroHardwareFramebufferCallback =
    @convention(c) () -> UInt
private typealias RetroHardwareProc =
    @convention(c) () -> Void
private typealias RetroHardwareProcAddressCallback =
    @convention(c) (UnsafePointer<CChar>?) -> RetroHardwareProc?

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
        schedule(samples: samples, frames: frames)
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

    init?() {
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(
                rawValue: UInt32(kCGLOGLPVersion_GL4_Core.rawValue)
            ),
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

private final class LibretroEnvironment {
    private static let preferredVariableValues = [
        // GLideN64's framebuffer path can produce valid but entirely black
        // frames through macOS's deprecated OpenGL implementation. The
        // multithreaded Angrylion renderer is CPU-based, accurate, and avoids
        // that hardware-context compatibility boundary on Apple Silicon.
        "parallel-n64-gfxplugin": "angrylion",
        "parallel-n64-rspplugin": "cxd4",
        "parallel-n64-angrylion-multithread": "all threads",
    ]

    private let strings = LibretroCStringStore()
    private let systemDirectory: UnsafePointer<CChar>
    private let saveDirectory: UnsafePointer<CChar>
    private let assetsDirectory: UnsafePointer<CChar>
    private var variables: [String: UnsafePointer<CChar>] = [:]
    private var hardwareRenderer: LibretroOpenGLRenderer?
    private var hardwareContextReset: RetroHardwareContextCallback?
    private var hardwareContextDestroy: RetroHardwareContextCallback?
    private var isHardwareContextActive = false

    private(set) var pixelFormat = LibretroABI.PixelFormat.zeroRGB1555
    private(set) var supportsNoGame = false
    private(set) var requestedShutdown = false

    init(systemDirectory: URL, saveDirectory: URL, assetsDirectory: URL) {
        self.systemDirectory = strings.store(systemDirectory.path)
        self.saveDirectory = strings.store(saveDirectory.path)
        self.assetsDirectory = strings.store(assetsDirectory.path)
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
        case .setSystemAVInfo, .setGeometry:
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
            let renderer = hardwareRenderer ?? LibretroOpenGLRenderer()
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
                if let defaultValue = values?.first, !defaultValue.isEmpty {
                    variables[key] = strings.store(
                        Self.preferredVariableValues[key] ?? defaultValue
                    )
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
        case saveQuickState
        case saveQuickStateAndStop
        case loadQuickState
        case rewind
    }

    private static let rewindCaptureInterval = 1.0
    private static let rewindByteLimit = 128 * 1_024 * 1_024
    private static let rewindEntryLimit = 90

    private struct Paths {
        let system: URL
        let saves: URL
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
        saveMemoryURL =
            request.saveSync?.localSaveURL
            ?? paths.saves.appending(path: "SaveRAM.srm")
        hasQuickState = FileManager.default.fileExists(atPath: quickStateURL.path)
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
        enqueue(.rewind)
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
            videoBuffer.publish(frame)
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
            videoBuffer.publish(frame)
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
        if inputState.consumeExitRequest() {
            emit(.controllerExitRequested)
        }
    }

    func input(
        port: UInt32,
        device: UInt32,
        index: UInt32,
        id: UInt32
    ) -> Int16 {
        guard port == 0 else {
            return 0
        }

        switch device & 0xFF {
        case LibretroABI.joypadDevice:
            return index == 0 ? inputState.value(for: id) : 0
        case LibretroABI.analogDevice:
            return inputState.analogValue(index: index, id: id)
        case LibretroABI.pointerDevice:
            return index == 0 ? inputState.pointerValue(for: id) : 0
        default:
            return 0
        }
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
        var nextRewindCapture = 0.0

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
                assetsDirectory: paths.assets
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
            let avInfo = try loadedCore.avInfo()
            try audioOutput.configure(sampleRate: avInfo.sampleRate)
            restoreSaveMemory(into: loadedCore)
            runtimeEnvironment.makeHardwareContextCurrent()
            let quickStateRestore =
                request.restoresQuickStateOnLaunch
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

            let frameDuration = 1 / avInfo.framesPerSecond
            var nextFrame = ProcessInfo.processInfo.systemUptime

            while !stopRequested {
                let didRewind = processCommands(
                    using: loadedCore,
                    rewindBuffer: &rewindBuffer,
                    rewindIsSupported: &rewindIsSupported,
                    nextRewindCapture: &nextRewindCapture
                )

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

                runtimeEnvironment.makeHardwareContextCurrent()
                loadedCore.run()
                captureRewindStateIfNeeded(
                    using: loadedCore,
                    rewindBuffer: &rewindBuffer,
                    rewindIsSupported: &rewindIsSupported,
                    nextRewindCapture: &nextRewindCapture
                )
                if runtimeEnvironment.requestedShutdown {
                    stop()
                }

                nextFrame += frameDuration
                let now = ProcessInfo.processInfo.systemUptime
                if nextFrame > now {
                    Thread.sleep(forTimeInterval: nextFrame - now)
                } else if now - nextFrame > 0.25 {
                    nextFrame = now
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
        nextRewindCapture: inout TimeInterval
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
                    nextRewindCapture = 0
                    emit(.rewindAvailabilityChanged(false))
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
                    nextRewindCapture = 0
                    audioOutput.flush()
                    emit(.rewindAvailabilityChanged(false))
                    emit(.quickStateLoaded)
                case .rewind:
                    guard rewindIsSupported else {
                        continue
                    }
                    guard let state = rewindBuffer.popLast() else {
                        emit(.rewindAvailabilityChanged(false))
                        continue
                    }
                    try core.loadState(state)
                    audioOutput.flush()
                    nextRewindCapture =
                        ProcessInfo.processInfo.systemUptime
                        + Self.rewindCaptureInterval
                    didRewind = true
                    emit(.rewound(canContinue: !rewindBuffer.isEmpty))
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
        emit(.quickStateSaved)
    }

    private func captureRewindStateIfNeeded(
        using core: LibretroCore,
        rewindBuffer: inout LibretroRewindBuffer,
        rewindIsSupported: inout Bool,
        nextRewindCapture: inout TimeInterval
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard rewindIsSupported, now >= nextRewindCapture else {
            return
        }
        nextRewindCapture = now + Self.rewindCaptureInterval

        do {
            let wasEmpty = rewindBuffer.isEmpty
            let state = try core.saveState()
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
        let contentIdentity = request.contentURL?.path ?? "content-free"
        let contentKey = SHA256.hash(data: Data(contentIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

        return Paths(
            system: request.systemDirectory
                ?? readableBundledSystemDirectory
                ?? root.appending(path: "System", directoryHint: .isDirectory),
            saves: root.appending(path: "Saves", directoryHint: .isDirectory),
            states: root.appending(path: "States", directoryHint: .isDirectory),
            assets: root.appending(path: "Assets", directoryHint: .isDirectory)
        )
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
