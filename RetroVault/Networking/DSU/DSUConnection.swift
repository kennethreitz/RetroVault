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

private extension DSUButtons {
    mutating func set(_ button: DSUButtons, when condition: Bool) {
        if condition {
            insert(button)
        }
    }
}
