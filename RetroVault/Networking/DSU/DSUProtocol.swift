import Foundation

/// Wire format for the DSU controller protocol, better known as "cemuhook".
///
/// RetroVault normally speaks the client half: it subscribes to a DSU server
/// over UDP and reads pad, touchpad, and motion state. Its Cemu integration
/// also republishes that state through the server half so Cemu can use either
/// a DSU bridge or an ordinary macOS controller. Everything in this file is
/// pure value manipulation so the codec stays testable without a socket.
///
/// Every field is little-endian. A datagram is a 16-byte header, a four-byte
/// message type, and a message payload:
///
///     0  magic       "DSUC" from a client, "DSUS" from a server
///     4  version     u16, currently 1001
///     6  length      u16, the message type plus payload
///     8  checksum    u32, CRC32 of the whole datagram with this field zeroed
///     12 sender ID   u32, stable for the lifetime of the sender
///     16 message     u32
///     20 payload
enum DSUProtocol {
    static let version: UInt16 = 1001
    static let defaultHost = "127.0.0.1"
    static let defaultPort: UInt16 = 26760
    static let slotCount: UInt8 = 4
    static let headerLength = 16
    static let messageTypeLength = 4

    static let clientMagic: [UInt8] = Array("DSUC".utf8)
    static let serverMagic: [UInt8] = Array("DSUS".utf8)
}

enum DSUMessageType: UInt32, Sendable {
    case protocolVersion = 0x0010_0000
    case controllerInfo = 0x0010_0001
    case controllerData = 0x0010_0002
}

enum DSUDecodingError: Error, Equatable {
    case tooShort
    case unexpectedMagic
    case unsupportedVersion(UInt16)
    case truncatedPayload
    case checksumMismatch
    case unsupportedMessage(UInt32)
}

// MARK: - Controller state

/// The digital buttons carried in the two bitmask bytes of a data packet.
///
/// The low byte is the packet's first mask (d-pad, sticks, Share, Options) and
/// the high byte is its second mask (face buttons, shoulders, triggers). Names
/// follow the protocol's DualShock vocabulary; translation to RetroPad happens
/// in `LibretroDSUInput`.
struct DSUButtons: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    init(firstMask: UInt8, secondMask: UInt8) {
        rawValue = UInt16(firstMask) | (UInt16(secondMask) << 8)
    }

    static let share = Self(rawValue: 1 << 0)
    static let leftStick = Self(rawValue: 1 << 1)
    static let rightStick = Self(rawValue: 1 << 2)
    static let options = Self(rawValue: 1 << 3)
    static let up = Self(rawValue: 1 << 4)
    static let right = Self(rawValue: 1 << 5)
    static let down = Self(rawValue: 1 << 6)
    static let left = Self(rawValue: 1 << 7)

    static let l2 = Self(rawValue: 1 << 8)
    static let r2 = Self(rawValue: 1 << 9)
    static let l1 = Self(rawValue: 1 << 10)
    static let r1 = Self(rawValue: 1 << 11)
    /// Square on a DualShock, the western face button.
    static let x = Self(rawValue: 1 << 12)
    /// Cross on a DualShock, the southern face button.
    static let a = Self(rawValue: 1 << 13)
    /// Circle on a DualShock, the eastern face button.
    static let b = Self(rawValue: 1 << 14)
    /// Triangle on a DualShock, the northern face button.
    static let y = Self(rawValue: 1 << 15)
}

/// One thumbstick axis pair, in the protocol's unsigned byte space where 128
/// is centered, 255 is right on X, and 255 is *up* on Y.
struct DSUStick: Equatable, Sendable {
    var x: UInt8 = 128
    var y: UInt8 = 128

    /// -1…1 with the Y axis flipped into screen orientation, so positive is
    /// down and matches what Libretro expects from an analog axis.
    var normalized: (x: Float, y: Float) {
        (Self.normalize(x), -Self.normalize(y))
    }

    private static func normalize(_ value: UInt8) -> Float {
        // 128 is the resting value, which leaves 127 of travel each way.
        let centered = Float(Int(value) - 128)
        return min(max(centered / 127, -1), 1)
    }
}

struct DSUTouch: Equatable, Sendable {
    var isActive = false
    var id: UInt8 = 0
    var x: UInt16 = 0
    var y: UInt16 = 0
}

/// Inertial state as the protocol reports it: acceleration in g and angular
/// velocity in degrees per second.
struct DSUMotion: Equatable, Sendable {
    var timestamp: UInt64 = 0
    var accelerationX: Float = 0
    var accelerationY: Float = 0
    var accelerationZ: Float = 0
    var pitch: Float = 0
    var yaw: Float = 0
    var roll: Float = 0

    /// True when a server is filling in the motion fields with zeroes, which
    /// is how a pad without inertial sensors reports. The timestamp is ignored
    /// because servers keep stamping packets either way.
    var isIdle: Bool {
        accelerationX == 0 && accelerationY == 0 && accelerationZ == 0
            && pitch == 0 && yaw == 0 && roll == 0
    }
}

enum DSUGyroModel: UInt8, Equatable, Sendable {
    case unavailable = 0
    case partial = 1
    case full = 2
}

/// The 11-byte descriptor every controller response begins with.
struct DSUSlotDescriptor: Equatable, Sendable {
    var slot: UInt8 = 0
    var isRegistered = false
    var gyroModel: DSUGyroModel = .unavailable
    var connectionType: UInt8 = 0
    var macAddress: UInt64 = 0
    var battery: UInt8 = 0
}

struct DSUPadState: Equatable, Sendable {
    var descriptor = DSUSlotDescriptor()
    var isConnected = false
    var packetNumber: UInt32 = 0
    var buttons: DSUButtons = []
    var isHomePressed = false
    var isTouchButtonPressed = false
    var leftStick = DSUStick()
    var rightStick = DSUStick()
    var touches: [DSUTouch] = [DSUTouch(), DSUTouch()]
    var motion = DSUMotion()

    var slot: UInt8 { descriptor.slot }

    var reportsMotion: Bool {
        descriptor.gyroModel != .unavailable || !motion.isIdle
    }
}

enum DSUMessage: Equatable, Sendable {
    case protocolVersion(UInt16)
    case controllerInfo(DSUSlotDescriptor)
    case controllerData(DSUPadState)
}

/// The small request surface a DSU server receives from clients such as Cemu.
enum DSUClientRequest: Equatable, Sendable {
    case protocolVersion
    case controllerInfo(slots: [UInt8])
    /// `nil` means the client subscribed to every published slot.
    case controllerData(slot: UInt8?)
}

// MARK: - Encoding

extension DSUProtocol {
    /// Subscribes to data for every slot the server publishes.
    static func padDataRequest(clientID: UInt32) -> Data {
        // Registration flags of zero mean "report all slots"; the slot and MAC
        // selectors that follow are ignored in that mode.
        encode(
            message: .controllerData,
            payload: [0, 0, 0, 0, 0, 0, 0, 0],
            clientID: clientID
        )
    }

    /// Asks the server which of its slots are occupied.
    static func controllerInfoRequest(clientID: UInt32) -> Data {
        var payload = littleEndianBytes(Int32(slotCount))
        payload.append(contentsOf: 0..<slotCount)
        return encode(message: .controllerInfo, payload: payload, clientID: clientID)
    }

    static func encode(
        message: DSUMessageType,
        payload: [UInt8],
        clientID: UInt32
    ) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerLength + messageTypeLength + payload.count)
        bytes.append(contentsOf: clientMagic)
        bytes.append(contentsOf: littleEndianBytes(version))
        bytes.append(
            contentsOf: littleEndianBytes(
                UInt16(messageTypeLength + payload.count)
            )
        )
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: littleEndianBytes(clientID))
        bytes.append(contentsOf: littleEndianBytes(message.rawValue))
        bytes.append(contentsOf: payload)

        // The checksum covers the datagram it sits inside, so it is written
        // over its own zeroed placeholder once the rest is in place.
        bytes.replaceSubrange(
            8..<12,
            with: littleEndianBytes(DSUChecksum.crc32(bytes))
        )
        return Data(bytes)
    }

    static func protocolVersionResponse(serverID: UInt32) -> Data {
        encodeServer(
            message: .protocolVersion,
            payload: littleEndianBytes(version) + [0, 0],
            serverID: serverID
        )
    }

    static func controllerInfoResponse(
        descriptor: DSUSlotDescriptor,
        isActive: Bool,
        serverID: UInt32
    ) -> Data {
        encodeServer(
            message: .controllerInfo,
            payload: descriptorPayload(descriptor) + [isActive ? 1 : 0],
            serverID: serverID
        )
    }

    static func controllerDataResponse(
        state: DSUPadState,
        publishedSlot: UInt8,
        serverID: UInt32
    ) -> Data {
        var descriptor = state.descriptor
        descriptor.slot = publishedSlot
        descriptor.isRegistered = state.isConnected

        var payload = descriptorPayload(descriptor)
        payload.append(state.isConnected ? 1 : 0)
        payload.append(contentsOf: littleEndianBytes(state.packetNumber))
        payload.append(UInt8(truncatingIfNeeded: state.buttons.rawValue))
        payload.append(UInt8(truncatingIfNeeded: state.buttons.rawValue >> 8))
        payload.append(state.isHomePressed ? 0xFF : 0)
        payload.append(state.isTouchButtonPressed ? 0xFF : 0)
        payload.append(contentsOf: [
            state.leftStick.x,
            state.leftStick.y,
            state.rightStick.x,
            state.rightStick.y,
        ])

        let analogButtons: [DSUButtons] = [
            .left, .down, .right, .up,
            .x, .a, .b, .y,
            .r1, .l1, .r2, .l2,
        ]
        payload.append(
            contentsOf: analogButtons.map { state.buttons.contains($0) ? 0xFF : 0 }
        )

        for index in 0..<2 {
            let touch = index < state.touches.count ? state.touches[index] : DSUTouch()
            payload.append(touch.isActive ? 1 : 0)
            payload.append(touch.id)
            payload.append(contentsOf: littleEndianBytes(touch.x))
            payload.append(contentsOf: littleEndianBytes(touch.y))
        }

        payload.append(contentsOf: littleEndianBytes(state.motion.timestamp))
        payload.append(contentsOf: littleEndianBytes(state.motion.accelerationX.bitPattern))
        payload.append(contentsOf: littleEndianBytes(state.motion.accelerationY.bitPattern))
        payload.append(contentsOf: littleEndianBytes(state.motion.accelerationZ.bitPattern))
        payload.append(contentsOf: littleEndianBytes(state.motion.pitch.bitPattern))
        payload.append(contentsOf: littleEndianBytes(state.motion.yaw.bitPattern))
        payload.append(contentsOf: littleEndianBytes(state.motion.roll.bitPattern))

        precondition(payload.count == 80)
        return encodeServer(
            message: .controllerData,
            payload: payload,
            serverID: serverID
        )
    }

    private static func descriptorPayload(_ descriptor: DSUSlotDescriptor) -> [UInt8] {
        var payload: [UInt8] = [
            descriptor.slot,
            descriptor.isRegistered ? 2 : 0,
            descriptor.gyroModel.rawValue,
            descriptor.connectionType,
        ]
        payload.append(
            contentsOf: (0..<6).map {
                UInt8(truncatingIfNeeded: descriptor.macAddress >> ($0 * 8))
            }
        )
        payload.append(descriptor.battery)
        return payload
    }

    private static func encodeServer(
        message: DSUMessageType,
        payload: [UInt8],
        serverID: UInt32
    ) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerLength + messageTypeLength + payload.count)
        bytes.append(contentsOf: serverMagic)
        bytes.append(contentsOf: littleEndianBytes(version))
        bytes.append(
            contentsOf: littleEndianBytes(
                UInt16(messageTypeLength + payload.count)
            )
        )
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: littleEndianBytes(serverID))
        bytes.append(contentsOf: littleEndianBytes(message.rawValue))
        bytes.append(contentsOf: payload)
        bytes.replaceSubrange(
            8..<12,
            with: littleEndianBytes(DSUChecksum.crc32(bytes))
        )
        return Data(bytes)
    }
}

// MARK: - Decoding

extension DSUProtocol {
    static func decodeClientRequest(_ datagram: Data) throws -> DSUClientRequest {
        var bytes = [UInt8](datagram)
        guard bytes.count >= headerLength + messageTypeLength else {
            throw DSUDecodingError.tooShort
        }
        guard Array(bytes[0..<4]) == clientMagic else {
            throw DSUDecodingError.unexpectedMagic
        }

        let reportedVersion = UInt16(bytes, at: 4)
        guard reportedVersion <= version else {
            throw DSUDecodingError.unsupportedVersion(reportedVersion)
        }
        let declaredLength = Int(UInt16(bytes, at: 6))
        guard bytes.count >= headerLength + declaredLength else {
            throw DSUDecodingError.truncatedPayload
        }
        bytes.removeLast(bytes.count - (headerLength + declaredLength))

        let checksum = UInt32(bytes, at: 8)
        for offset in 8..<12 {
            bytes[offset] = 0
        }
        guard DSUChecksum.crc32(bytes) == checksum else {
            throw DSUDecodingError.checksumMismatch
        }

        let rawMessage = UInt32(bytes, at: 16)
        guard let message = DSUMessageType(rawValue: rawMessage) else {
            throw DSUDecodingError.unsupportedMessage(rawMessage)
        }
        let payload = Array(bytes[(headerLength + messageTypeLength)...])
        switch message {
        case .protocolVersion:
            return .protocolVersion
        case .controllerInfo:
            guard payload.count >= 4 else {
                throw DSUDecodingError.truncatedPayload
            }
            let count = min(Int(UInt32(payload, at: 0)), 4)
            guard payload.count >= 4 + count else {
                throw DSUDecodingError.truncatedPayload
            }
            return .controllerInfo(slots: Array(payload[4..<(4 + count)]))
        case .controllerData:
            guard payload.count >= 8 else {
                throw DSUDecodingError.truncatedPayload
            }
            let registersBySlot = payload[0] & 0x01 != 0
            return .controllerData(slot: registersBySlot ? payload[1] : nil)
        }
    }

    static func decode(_ datagram: Data) throws -> DSUMessage {
        var bytes = [UInt8](datagram)
        guard bytes.count >= headerLength + messageTypeLength else {
            throw DSUDecodingError.tooShort
        }
        guard Array(bytes[0..<4]) == serverMagic else {
            throw DSUDecodingError.unexpectedMagic
        }

        let reportedVersion = UInt16(bytes, at: 4)
        guard reportedVersion <= version else {
            throw DSUDecodingError.unsupportedVersion(reportedVersion)
        }

        let declaredLength = Int(UInt16(bytes, at: 6))
        guard bytes.count >= headerLength + declaredLength else {
            throw DSUDecodingError.truncatedPayload
        }
        // Trust the declared length over the datagram length so a padded
        // packet still checksums the way its sender computed it.
        bytes.removeLast(bytes.count - (headerLength + declaredLength))

        let checksum = UInt32(bytes, at: 8)
        for offset in 8..<12 {
            bytes[offset] = 0
        }
        guard DSUChecksum.crc32(bytes) == checksum else {
            throw DSUDecodingError.checksumMismatch
        }

        let rawMessage = UInt32(bytes, at: 16)
        guard let message = DSUMessageType(rawValue: rawMessage) else {
            throw DSUDecodingError.unsupportedMessage(rawMessage)
        }

        let payload = Array(bytes[(headerLength + messageTypeLength)...])
        switch message {
        case .protocolVersion:
            guard payload.count >= 2 else {
                throw DSUDecodingError.truncatedPayload
            }
            return .protocolVersion(UInt16(payload, at: 0))
        case .controllerInfo:
            guard payload.count >= 11 else {
                throw DSUDecodingError.truncatedPayload
            }
            return .controllerInfo(slotDescriptor(payload))
        case .controllerData:
            return .controllerData(try padState(payload))
        }
    }

    private static func slotDescriptor(_ payload: [UInt8]) -> DSUSlotDescriptor {
        var macAddress: UInt64 = 0
        for offset in (4..<10).reversed() {
            macAddress = (macAddress << 8) | UInt64(payload[offset])
        }

        return DSUSlotDescriptor(
            slot: payload[0],
            isRegistered: payload[1] == 2,
            gyroModel: DSUGyroModel(rawValue: payload[2]) ?? .unavailable,
            connectionType: payload[3],
            macAddress: macAddress,
            battery: payload[10]
        )
    }

    private static func padState(_ payload: [UInt8]) throws -> DSUPadState {
        // 11 descriptor bytes, then 69 bytes of buttons, sticks, touch, and
        // motion. Analog button pressures occupy bytes 24…35 and are skipped:
        // RetroPad only consumes the digital bits.
        guard payload.count >= 80 else {
            throw DSUDecodingError.truncatedPayload
        }

        var state = DSUPadState()
        state.descriptor = slotDescriptor(payload)
        state.isConnected = payload[11] == 1
        state.packetNumber = UInt32(payload, at: 12)
        state.buttons = DSUButtons(firstMask: payload[16], secondMask: payload[17])
        state.isHomePressed = payload[18] != 0
        state.isTouchButtonPressed = payload[19] != 0
        state.leftStick = DSUStick(x: payload[20], y: payload[21])
        state.rightStick = DSUStick(x: payload[22], y: payload[23])
        state.touches = [
            touch(payload, at: 36),
            touch(payload, at: 42),
        ]
        state.motion = DSUMotion(
            timestamp: UInt64(payload, at: 48),
            accelerationX: Float(payload, at: 56),
            accelerationY: Float(payload, at: 60),
            accelerationZ: Float(payload, at: 64),
            pitch: Float(payload, at: 68),
            yaw: Float(payload, at: 72),
            roll: Float(payload, at: 76)
        )
        return state
    }

    private static func touch(_ payload: [UInt8], at offset: Int) -> DSUTouch {
        DSUTouch(
            isActive: payload[offset] != 0,
            id: payload[offset + 1],
            x: UInt16(payload, at: offset + 2),
            y: UInt16(payload, at: offset + 4)
        )
    }
}

// MARK: - Little-endian primitives

private func littleEndianBytes<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

private extension FixedWidthInteger {
    init(_ bytes: [UInt8], at offset: Int) {
        var value = Self.zero
        for index in (0..<MemoryLayout<Self>.size).reversed() {
            value = (value << 8) | Self(bytes[offset + index])
        }
        self = value
    }
}

private extension Float {
    init(_ bytes: [UInt8], at offset: Int) {
        self = Float(bitPattern: UInt32(bytes, at: offset))
    }
}

/// The CRC-32 every DSU datagram carries, using the standard reflected
/// polynomial shared with zlib and PNG.
enum DSUChecksum {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var remainder = UInt32(index)
            for _ in 0..<8 {
                remainder =
                    remainder & 1 == 1
                    ? (remainder >> 1) ^ 0xEDB8_8320
                    : remainder >> 1
            }
            return remainder
        }
    }()

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var remainder: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            remainder = (remainder >> 8) ^ table[Int((remainder ^ UInt32(byte)) & 0xFF)]
        }
        return remainder ^ 0xFFFF_FFFF
    }
}
