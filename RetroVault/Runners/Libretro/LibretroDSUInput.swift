import Foundation

/// Sensor readings in the units Libretro's sensor interface expects:
/// acceleration in m/s² and angular velocity in radians per second.
struct LibretroSensorValues: Equatable, Sendable {
    var accelerationX: Float = 0
    var accelerationY: Float = 0
    var accelerationZ: Float = 0
    var gyroscopeX: Float = 0
    var gyroscopeY: Float = 0
    var gyroscopeZ: Float = 0

    static func from(_ motion: DSUMotion) -> Self {
        // DSU reports acceleration in g and rotation in degrees per second.
        let gravity: Float = 9.806_65
        let radiansPerDegree = Float.pi / 180

        return Self(
            accelerationX: motion.accelerationX * gravity,
            accelerationY: motion.accelerationY * gravity,
            accelerationZ: motion.accelerationZ * gravity,
            // Pitch, yaw, and roll are the device's X, Y, and Z axes.
            gyroscopeX: motion.pitch * radiansPerDegree,
            gyroscopeY: motion.yaw * radiansPerDegree,
            gyroscopeZ: motion.roll * radiansPerDegree
        )
    }
}

/// Touchpad coordinate ranges are device-specific and the protocol asks clients
/// to calibrate, so the range starts at the DualShock 4's nominal extents and
/// widens whenever a pad reports something larger.
struct DSUTouchCalibration: Equatable, Sendable {
    private(set) var maximumX: UInt16 = 1_919
    private(set) var maximumY: UInt16 = 941

    mutating func normalized(_ touch: DSUTouch) -> (x: Int16, y: Int16) {
        maximumX = max(maximumX, touch.x)
        maximumY = max(maximumY, touch.y)
        return (
            Self.scale(touch.x, maximum: maximumX),
            Self.scale(touch.y, maximum: maximumY)
        )
    }

    private static func scale(_ value: UInt16, maximum: UInt16) -> Int16 {
        guard maximum > 0 else {
            return 0
        }
        // Libretro's pointer space runs -32767…32767 across the visible area.
        let fraction = Double(value) / Double(maximum)
        return Int16(clamping: Int((fraction * 2 - 1) * Double(Int16.max)))
    }
}

/// Translates a DSU pad packet into the values `LibretroInputState` already
/// tracks for a physical controller.
///
/// Buttons that the runtime handles specially — Start and Select for the exit
/// chord, the stick clicks for rewind and fast-forward — are reported
/// separately rather than folded into the mask, so a DSU pad obeys the same
/// rules as a controller attached over Bluetooth.
enum LibretroDSUInput {
    struct Pointer: Equatable, Sendable {
        var x: Int16
        var y: Int16
        var isPressed: Bool
    }

    struct Pad: Equatable, Sendable {
        var buttons: UInt16 = 0
        var isSelectPressed = false
        var isStartPressed = false
        var isLeftStickPressed = false
        var isRightStickPressed = false
        var leftAnalogX: Int16 = 0
        var leftAnalogY: Int16 = 0
        var rightAnalogX: Int16 = 0
        var rightAnalogY: Int16 = 0
        var pointer: Pointer?
        var sensors = LibretroSensorValues()
    }

    static func pad(
        from state: DSUPadState,
        layout: ControllerFaceButtonLayout,
        calibration: inout DSUTouchCalibration
    ) -> Pad {
        var pad = Pad()
        let buttons = state.buttons

        var mask: UInt16 = 0
        mask.set(.up, when: buttons.contains(.up))
        mask.set(.down, when: buttons.contains(.down))
        mask.set(.left, when: buttons.contains(.left))
        mask.set(.right, when: buttons.contains(.right))
        // The protocol names its face buttons after a DualShock, but a server
        // bridging a Nintendo pad fills those slots by label rather than by
        // position. That is the same ambiguity an attached controller has, so
        // it resolves the same way.
        mask |= LibretroInputState.faceButtonMask(
            buttonAPressed: buttons.contains(.a),
            buttonBPressed: buttons.contains(.b),
            buttonXPressed: buttons.contains(.x),
            buttonYPressed: buttons.contains(.y),
            layout: layout
        )
        mask.set(.l, when: buttons.contains(.l1))
        mask.set(.r, when: buttons.contains(.r1))
        mask.set(.l2, when: buttons.contains(.l2))
        mask.set(.r2, when: buttons.contains(.r2))
        pad.buttons = mask

        pad.isSelectPressed = buttons.contains(.share)
        pad.isStartPressed = buttons.contains(.options)
        pad.isLeftStickPressed = buttons.contains(.leftStick)
        pad.isRightStickPressed = buttons.contains(.rightStick)

        let left = state.leftStick.normalized
        let right = state.rightStick.normalized
        pad.leftAnalogX = analogAxis(left.x)
        pad.leftAnalogY = analogAxis(left.y)
        pad.rightAnalogX = analogAxis(right.x)
        pad.rightAnalogY = analogAxis(right.y)

        // A contact on the touchpad is the stylus-down that Libretro's pointer
        // device expects, so touching is enough; the physical click is not
        // required on top of it.
        if let touch = state.touches.first(where: \.isActive) {
            let position = calibration.normalized(touch)
            pad.pointer = Pointer(x: position.x, y: position.y, isPressed: true)
        }

        pad.sensors = .from(state.motion)
        return pad
    }

    private static func analogAxis(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamping: Int(clamped * Float(Int16.max)))
    }
}

private extension UInt16 {
    mutating func set(_ button: LibretroButton, when condition: Bool) {
        if condition {
            self |= button.mask
        }
    }
}
