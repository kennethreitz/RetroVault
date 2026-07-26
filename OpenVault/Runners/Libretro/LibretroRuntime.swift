@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
@preconcurrency import GameController
import Observation
import OSLog

struct LibretroRunRequest: Codable, Hashable, Sendable {
    let title: String
    let coreID: String
    let contentURL: URL?

    static let pipelineTest = Self(
        title: "2048",
        coreID: "libretro-2048",
        contentURL: nil
    )
}

struct LibretroVideoFrame: Sendable {
    let pixels: Data
    let width: Int
    let height: Int
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

    func pollController() {
        guard let gamepad = GCController.controllers().first?.extendedGamepad else {
            lock.lock()
            controllerButtons = 0
            polledButtons = keyboardButtons | pendingKeyboardPresses
            pendingKeyboardPresses = 0
            lock.unlock()
            return
        }

        var buttons: UInt16 = 0
        buttons.set(.up, when: gamepad.dpad.up.isPressed)
        buttons.set(.down, when: gamepad.dpad.down.isPressed)
        buttons.set(.left, when: gamepad.dpad.left.isPressed)
        buttons.set(.right, when: gamepad.dpad.right.isPressed)
        buttons.set(.b, when: gamepad.buttonA.isPressed)
        buttons.set(.a, when: gamepad.buttonB.isPressed)
        buttons.set(.y, when: gamepad.buttonX.isPressed)
        buttons.set(.x, when: gamepad.buttonY.isPressed)
        buttons.set(.l, when: gamepad.leftShoulder.isPressed)
        buttons.set(.r, when: gamepad.rightShoulder.isPressed)
        buttons.set(.l2, when: gamepad.leftTrigger.isPressed)
        buttons.set(.r2, when: gamepad.rightTrigger.isPressed)
        buttons.set(.select, when: gamepad.buttonOptions?.isPressed == true)
        buttons.set(.start, when: gamepad.buttonMenu.isPressed)

        lock.lock()
        controllerButtons = buttons
        polledButtons = keyboardButtons | pendingKeyboardPresses | controllerButtons
        pendingKeyboardPresses = 0
        lock.unlock()
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

    let request: LibretroRunRequest
    let videoBuffer = LibretroVideoBuffer()
    let input = LibretroInputState()

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var message: String?
    private(set) var hasQuickState = false

    private let engine: LibretroEngine

    init(request: LibretroRunRequest) {
        self.request = request
        engine = LibretroEngine(
            request: request,
            videoBuffer: videoBuffer,
            input: input
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
        message = nil
        OpenVaultLog.libretro.notice(
            "Starting core \(self.request.coreID, privacy: .public)"
        )
        engine.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event)
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
        message = "Game reset."
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

    private func receive(_ event: LibretroEngine.Event) {
        switch event {
        case let .running(coreName, framesPerSecond):
            phase = .running(coreName: coreName, framesPerSecond: framesPerSecond)
            OpenVaultLog.libretro.notice(
                "Core \(coreName, privacy: .public) is running at \(framesPerSecond, privacy: .public) FPS"
            )
        case .stopped:
            phase = .stopped
            isPaused = false
            OpenVaultLog.libretro.notice("Libretro session stopped")
        case let .failed(error):
            phase = .failed(error)
            isPaused = false
            OpenVaultLog.libretro.error("Libretro session failed: \(error)")
        case .quickStateSaved:
            hasQuickState = true
            OpenVaultLog.libretro.info("Quick state saved")
            message = "Quick state saved locally."
        case .quickStateLoaded:
            message = "Quick state restored."
        case let .notice(text):
            message = text
        }
    }
}

private enum LibretroRuntimeError: LocalizedError {
    case alreadyRunning
    case couldNotLoadCore(String)
    case missingSymbol(String)
    case unsupportedAPIVersion(UInt32)
    case contentRejected
    case invalidSystemInformation
    case unsupportedPixelFormat(Int32)
    case stateUnavailable
    case stateOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "OpenVault currently supports one active Libretro session."
        case let .couldNotLoadCore(reason):
            "The Libretro core could not be loaded: \(reason)"
        case let .missingSymbol(symbol):
            "The bundled core is invalid because it does not export \(symbol)."
        case let .unsupportedAPIVersion(version):
            "The core uses unsupported Libretro API version \(version)."
        case .contentRejected:
            "The core rejected this game file."
        case .invalidSystemInformation:
            "The core returned invalid system or video information."
        case let .unsupportedPixelFormat(format):
            "The core requested unsupported pixel format \(format)."
        case .stateUnavailable:
            "This core does not expose save states for the current game."
        case let .stateOperationFailed(reason):
            "The save state operation failed: \(reason)"
        }
    }
}

private enum LibretroABI {
    static let apiVersion: UInt32 = 1
    static let joypadDevice: UInt32 = 1
    static let joypadMaskID: UInt32 = 256
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

private protocol LibretroCallbackTarget: AnyObject {
    func environment(command: UInt32, data: UnsafeMutableRawPointer?) -> Bool
    func video(data: UnsafeRawPointer?, width: UInt32, height: UInt32, pitch: Int)
    func audio(left: Int16, right: Int16)
    func audio(data: UnsafePointer<Int16>?, frames: Int) -> Int
    func pollInput()
    func input(port: UInt32, device: UInt32, index: UInt32, id: UInt32) -> Int16
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
    private let strings = LibretroCStringStore()
    private let systemDirectory: UnsafePointer<CChar>
    private let saveDirectory: UnsafePointer<CChar>
    private let assetsDirectory: UnsafePointer<CChar>
    private var variables: [String: UnsafePointer<CChar>] = [:]

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
            return false
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
        }
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
                    variables[key] = strings.store(defaultValue)
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
        case quickStateSaved
        case quickStateLoaded
        case notice(String)
    }

    private enum Command {
        case reset
        case saveQuickState
        case loadQuickState
    }

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

    private var environment: LibretroEnvironment?
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var commands: [Command] = []
    private var isActive = false
    private var shouldStop = false
    private var isPaused = false

    init(
        request: LibretroRunRequest,
        videoBuffer: LibretroVideoBuffer,
        input: LibretroInputState
    ) {
        self.request = request
        self.videoBuffer = videoBuffer
        inputState = input

        let paths = Self.paths(for: request)
        self.paths = paths
        quickStateURL = paths.states.appending(path: "Quick.state")
        saveMemoryURL = paths.saves.appending(path: "SaveRAM.srm")
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

    func loadQuickState() {
        enqueue(.loadQuickState)
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
    }

    func input(
        port: UInt32,
        device: UInt32,
        index: UInt32,
        id: UInt32
    ) -> Int16 {
        guard port == 0, device & 0xFF == LibretroABI.joypadDevice, index == 0 else {
            return 0
        }
        return inputState.value(for: id)
    }

    private func runLoop() {
        var core: LibretroCore?
        var initialized = false
        var loaded = false
        var failed = false

        defer {
            if loaded, let core {
                persistSaveMemory(from: core)
                core.unloadGame()
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
            let installation = try LibretroInstallation.bundled()
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
            try loadedCore.loadGame(
                contentURL: request.contentURL,
                needsFullPath: systemInfo.needsFullPath
            )
            loaded = true

            let avInfo = try loadedCore.avInfo()
            try audioOutput.configure(sampleRate: avInfo.sampleRate)
            restoreSaveMemory(into: loadedCore)
            emit(
                .running(
                    coreName: "\(manifestCore.displayName) · \(systemInfo.name) \(systemInfo.version)",
                    framesPerSecond: avInfo.framesPerSecond
                )
            )

            let frameDuration = 1 / avInfo.framesPerSecond
            var nextFrame = ProcessInfo.processInfo.systemUptime

            while !stopRequested {
                processCommands(using: loadedCore)

                if paused {
                    Thread.sleep(forTimeInterval: 0.01)
                    nextFrame = ProcessInfo.processInfo.systemUptime
                    continue
                }

                loadedCore.run()
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

    private func processCommands(using core: LibretroCore) {
        controlLock.lock()
        let pending = commands
        commands.removeAll()
        controlLock.unlock()

        for command in pending {
            do {
                switch command {
                case .reset:
                    core.reset()
                case .saveQuickState:
                    let data = try core.saveState()
                    try data.write(to: quickStateURL, options: .atomic)
                    emit(.quickStateSaved)
                case .loadQuickState:
                    guard FileManager.default.fileExists(atPath: quickStateURL.path) else {
                        throw LibretroRuntimeError.stateUnavailable
                    }
                    let data = try Data(contentsOf: quickStateURL)
                    try core.loadState(data)
                    emit(.quickStateLoaded)
                }
            } catch {
                emit(.notice(error.localizedDescription))
            }
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

    private func persistSaveMemory(from core: LibretroCore) {
        guard let (source, size) = core.saveMemory() else {
            return
        }
        let data = Data(bytes: source, count: size)
        do {
            try data.write(to: saveMemoryURL, options: .atomic)
        } catch {
            emit(.notice("OpenVault could not save battery-backed memory: \(error.localizedDescription)"))
        }
    }

    private func prepareDirectories() throws {
        for directory in [paths.system, paths.saves, paths.states, paths.assets] {
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

        return Paths(
            system: root.appending(path: "System", directoryHint: .isDirectory),
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
