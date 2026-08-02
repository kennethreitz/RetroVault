import CoreHaptics
@preconcurrency import GameController
import Foundation

/// The process-wide controller hub.
///
/// External DSU slots and controllers exposed by GameController are converted
/// into one stable, four-player DSU-shaped stream. In-process consumers read
/// the value snapshots directly; hosted emulators can consume the same stream
/// through RetroVault's localhost DSU relay.
final class DSUConnection: DSUPadReading, @unchecked Sendable {
    static let shared = DSUConnection()

    private let lock = NSLock()
    private var activeClient: DSUClient?
    private var storedLayout = DSUPreferences.defaultLayout
    private var assignedNativeControllers = Array<GCController?>(
        repeating: nil,
        count: Int(DSUProtocol.slotCount)
    )

    private init() {}

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

    func currentPads() -> [RoutedDSUPad] {
        lock.lock()
        let client = activeClient
        let networkLayout = storedLayout
        lock.unlock()

        let networkPads = Array(
            (client?.currentPads() ?? []).prefix(Int(DSUProtocol.slotCount))
        )
        let connectedControllers = GCController.controllers().filter {
            $0.extendedGamepad != nil
        }

        lock.lock()
        defer { lock.unlock() }

        let occupiedNetworkSlots = Set(networkPads.map { Int($0.slot) })
        for index in assignedNativeControllers.indices {
            if occupiedNetworkSlots.contains(index) {
                assignedNativeControllers[index] = nil
                continue
            }
            guard let assigned = assignedNativeControllers[index] else {
                continue
            }
            if !connectedControllers.contains(where: { $0 === assigned }) {
                assignedNativeControllers[index] = nil
            }
        }

        var unassigned = connectedControllers.filter { controller in
            !assignedNativeControllers.contains(where: { $0 === controller })
        }
        if
            assignedNativeControllers[0] == nil,
            !occupiedNetworkSlots.contains(0),
            let current = GCController.current,
            let index = unassigned.firstIndex(where: { $0 === current })
        {
            assignedNativeControllers[0] = unassigned.remove(at: index)
        }
        for index in assignedNativeControllers.indices
        where assignedNativeControllers[index] == nil
            && !occupiedNetworkSlots.contains(index)
        {
            guard !unassigned.isEmpty else { break }
            assignedNativeControllers[index] = unassigned.removeFirst()
        }

        var routed = networkPads.map { pad in
            return RoutedDSUPad(
                state: pad,
                layout: networkLayout,
                source: .network(remoteSlot: pad.slot)
            )
        }
        for nativeIndex in assignedNativeControllers.indices {
            guard
                let controller = assignedNativeControllers[nativeIndex],
                let state = Self.nativeState(
                    from: controller,
                    slot: UInt8(nativeIndex)
                )
            else {
                continue
            }
            routed.append(
                RoutedDSUPad(
                    state: state,
                    layout: ControllerFaceButtonLayout.resolve(
                        vendorName: controller.vendorName,
                        productCategory: controller.productCategory
                    ),
                    source: .gameController
                )
            )
        }
        return routed.sorted { $0.state.slot < $1.state.slot }
    }

    func currentPad() -> RoutedDSUPad? {
        currentPads().first
    }

    @discardableResult
    func setRumble(slot: UInt8, strong: UInt16, weak: UInt16) -> Bool {
        // Refresh assignments before resolving the output path so a controller
        // connected after the last input poll can still receive the effect.
        let routedPad = currentPads().first { $0.state.slot == slot }
        guard let routedPad else { return false }

        switch routedPad.source {
        case let .network(remoteSlot):
            lock.lock()
            let client = activeClient
            lock.unlock()
            return client?.setRumble(
                slot: remoteSlot,
                strong: strong,
                weak: weak
            ) ?? false
        case .gameController:
            lock.lock()
            let index = Int(slot)
            let controller = assignedNativeControllers.indices.contains(index)
                ? assignedNativeControllers[index]
                : nil
            lock.unlock()
            guard let controller else { return false }
            return NativeControllerRumble.shared.set(
                controller: controller,
                strong: strong,
                weak: weak
            )
        }
    }

    private static func nativeState(
        from controller: GCController,
        slot: UInt8
    ) -> DSUPadState? {
        guard let gamepad = controller.extendedGamepad else { return nil }
        var buttons: DSUButtons = []
        buttons.set(.up, when: gamepad.dpad.up.isPressed)
        buttons.set(.down, when: gamepad.dpad.down.isPressed)
        buttons.set(.left, when: gamepad.dpad.left.isPressed)
        buttons.set(.right, when: gamepad.dpad.right.isPressed)
        buttons.set(.a, when: gamepad.buttonA.isPressed)
        buttons.set(.b, when: gamepad.buttonB.isPressed)
        buttons.set(.x, when: gamepad.buttonX.isPressed)
        buttons.set(.y, when: gamepad.buttonY.isPressed)
        buttons.set(.l1, when: gamepad.leftShoulder.isPressed)
        buttons.set(.r1, when: gamepad.rightShoulder.isPressed)
        buttons.set(.l2, when: gamepad.leftTrigger.isPressed)
        buttons.set(.r2, when: gamepad.rightTrigger.isPressed)
        buttons.set(.share, when: gamepad.buttonOptions?.isPressed == true)
        buttons.set(.options, when: gamepad.buttonMenu.isPressed)
        buttons.set(.leftStick, when: gamepad.leftThumbstickButton?.isPressed == true)
        buttons.set(.rightStick, when: gamepad.rightThumbstickButton?.isPressed == true)

        return DSUPadState(
            descriptor: DSUSlotDescriptor(
                slot: slot,
                isRegistered: true,
                gyroModel: .unavailable,
                connectionType: 2,
                macAddress: 0x52_56_48_55_42_00 &+ UInt64(slot),
                battery: 5
            ),
            isConnected: true,
            buttons: buttons,
            isHomePressed: gamepad.buttonHome?.isPressed == true,
            leftStick: DSUStick(
                x: axisByte(gamepad.leftThumbstick.xAxis.value),
                y: axisByte(gamepad.leftThumbstick.yAxis.value)
            ),
            rightStick: DSUStick(
                x: axisByte(gamepad.rightThumbstick.xAxis.value),
                y: axisByte(gamepad.rightThumbstick.yAxis.value)
            )
        )
    }

    private static func axisByte(_ value: Float) -> UInt8 {
        let clamped = min(max(value, -1), 1)
        let scale: Float = clamped >= 0 ? 127 : 128
        return UInt8(clamping: 128 + Int((clamped * scale).rounded()))
    }
}

/// Keeps one continuous Core Haptics player per attached native controller.
///
/// Libretro exposes a low-frequency and a high-frequency motor. Core Haptics
/// exposes intensity and sharpness instead, so the two amplitudes are folded
/// into those matching perceptual dimensions. DSU controllers retain their
/// two independent motor values and never take this approximation path.
private final class NativeControllerRumble: @unchecked Sendable {
    static let shared = NativeControllerRumble()

    private struct Output {
        let controller: GCController
        let engine: CHHapticEngine
        let player: any CHHapticAdvancedPatternPlayer
    }

    private let queue = DispatchQueue(
        label: "org.kennethreitz.RetroVault.controller-rumble",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var supportedControllers: Set<ObjectIdentifier> = []
    private var unsupportedControllers: Set<ObjectIdentifier> = []
    private var outputs: [ObjectIdentifier: Output] = [:]

    @discardableResult
    func set(controller: GCController, strong: UInt16, weak: UInt16) -> Bool {
        let id = ObjectIdentifier(controller)
        lock.lock()
        let knownSupported = supportedControllers.contains(id)
        let knownUnsupported = unsupportedControllers.contains(id)
        lock.unlock()
        guard !knownUnsupported else { return false }

        queue.async { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.apply(controller: controller, strong: strong, weak: weak)
        }
        // The first request is optimistic because engine creation belongs off
        // the emulator thread. Subsequent requests report the discovered state.
        return knownSupported || controller.haptics != nil
    }

    private func apply(controller: GCController, strong: UInt16, weak: UInt16) {
        let id = ObjectIdentifier(controller)
        if strong == 0, weak == 0 {
            if let output = output(for: id) {
                try? output.player.stop(atTime: CHHapticTimeImmediate)
                output.engine.stop()
                removeOutput(for: id)
            }
            return
        }

        do {
            let output = try output(for: controller)
            let low = Float(strong) / Float(UInt16.max)
            let high = Float(weak) / Float(UInt16.max)
            let intensity = max(low, high)
            let sharpness = intensity > 0 ? high / intensity : 0
            try output.player.sendParameters(
                [
                    CHHapticDynamicParameter(
                        parameterID: .hapticIntensityControl,
                        value: intensity,
                        relativeTime: 0
                    ),
                    CHHapticDynamicParameter(
                        parameterID: .hapticSharpnessControl,
                        value: sharpness,
                        relativeTime: 0
                    ),
                ],
                atTime: CHHapticTimeImmediate
            )
            mark(id, supported: true)
        } catch {
            mark(id, supported: false)
            RetroVaultLog.network.debug(
                "Native controller rumble unavailable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func output(for controller: GCController) throws -> Output {
        let id = ObjectIdentifier(controller)
        if let output = output(for: id) {
            return output
        }
        guard
            let engine = controller.haptics?.createEngine(
                withLocality: GCHapticsLocality.default
            )
        else {
            throw NativeControllerRumbleError.unsupported
        }
        try engine.start()
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: 0
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: 0
                ),
            ],
            relativeTime: 0,
            duration: 1
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        player.loopEnd = 1
        try player.start(atTime: CHHapticTimeImmediate)
        let output = Output(
            controller: controller,
            engine: engine,
            player: player
        )
        lock.lock()
        outputs[id] = output
        lock.unlock()
        return output
    }

    private func output(for id: ObjectIdentifier) -> Output? {
        lock.lock()
        defer { lock.unlock() }
        return outputs[id]
    }

    private func removeOutput(for id: ObjectIdentifier) {
        lock.lock()
        outputs.removeValue(forKey: id)
        lock.unlock()
    }

    private func mark(_ id: ObjectIdentifier, supported: Bool) {
        lock.lock()
        if supported {
            supportedControllers.insert(id)
            unsupportedControllers.remove(id)
        } else {
            supportedControllers.remove(id)
            unsupportedControllers.insert(id)
            outputs.removeValue(forKey: id)
        }
        lock.unlock()
    }
}

private enum NativeControllerRumbleError: Error {
    case unsupported
}

private extension DSUButtons {
    mutating func set(_ button: DSUButtons, when condition: Bool) {
        if condition {
            insert(button)
        }
    }
}
