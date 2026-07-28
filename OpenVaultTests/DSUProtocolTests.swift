import Foundation
import Testing

@testable import OpenVault

@Suite("DSU protocol")
struct DSUProtocolTests {
  @Test("Computes the CRC-32 the protocol specifies")
  func computesChecksum() {
    // The canonical check value for the reflected CRC-32 polynomial.
    #expect(DSUChecksum.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    #expect(DSUChecksum.crc32([]) == 0)
  }

  @Test("Frames a pad data request the way a server expects")
  func encodesPadDataRequest() throws {
    let request = DSUProtocol.padDataRequest(clientID: 0x1234_5678)
    let bytes = [UInt8](request)

    #expect(bytes.count == 28)
    #expect(Array(bytes[0..<4]) == Array("DSUC".utf8))
    #expect(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8) == 1_001)
    // The length covers the message type plus its eight-byte payload.
    #expect(UInt16(bytes[6]) | (UInt16(bytes[7]) << 8) == 12)
    #expect(Array(bytes[12..<16]) == [0x78, 0x56, 0x34, 0x12])
    #expect(Array(bytes[16..<20]) == [0x02, 0x00, 0x10, 0x00])
    // Registration flags of zero subscribe to every slot.
    #expect(Array(bytes[20..<28]) == Array(repeating: 0, count: 8))
  }

  @Test("Carries a checksum over the whole datagram")
  func encodesChecksum() throws {
    var bytes = [UInt8](DSUProtocol.padDataRequest(clientID: 7))
    let checksum =
      UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16)
      | (UInt32(bytes[11]) << 24)

    #expect(checksum != 0)
    for offset in 8..<12 {
      bytes[offset] = 0
    }
    #expect(DSUChecksum.crc32(bytes) == checksum)
  }

  @Test("Decodes a controller data packet")
  func decodesControllerData() throws {
    let packet = DSUPacketFixture(
      slot: 2,
      firstMask: 0b1000_1001,  // D-pad left, Options, Share
      secondMask: 0b0010_0100,  // Cross and L1
      leftStick: (200, 220),
      rightStick: (40, 30),
      touch: (id: 4, x: 960, y: 470),
      motion: (0, 1, 0, 10, -20, 30)
    ).data()

    guard case let .controllerData(pad) = try DSUProtocol.decode(packet) else {
      Issue.record("Expected controller data.")
      return
    }

    #expect(pad.slot == 2)
    #expect(pad.isConnected)
    #expect(pad.descriptor.gyroModel == .full)
    #expect(pad.buttons.contains(.left))
    #expect(pad.buttons.contains(.options))
    #expect(pad.buttons.contains(.share))
    #expect(pad.buttons.contains(.a))
    #expect(pad.buttons.contains(.l1))
    #expect(!pad.buttons.contains(.right))
    #expect(!pad.buttons.contains(.b))
    #expect(pad.leftStick.x == 200)
    #expect(pad.leftStick.y == 220)
    #expect(pad.rightStick.x == 40)
    #expect(pad.touches[0].isActive)
    #expect(pad.touches[0].id == 4)
    #expect(pad.touches[0].x == 960)
    #expect(pad.touches[0].y == 470)
    #expect(!pad.touches[1].isActive)
    #expect(pad.motion.accelerationY == 1)
    #expect(pad.motion.pitch == 10)
    #expect(pad.motion.yaw == -20)
    #expect(pad.motion.roll == 30)
    #expect(pad.reportsMotion)
  }

  @Test("Reads sticks as centered when a pad is at rest")
  func decodesRestingSticks() throws {
    let packet = DSUPacketFixture().data()
    guard case let .controllerData(pad) = try DSUProtocol.decode(packet) else {
      Issue.record("Expected controller data.")
      return
    }

    #expect(pad.buttons.isEmpty)
    #expect(pad.leftStick.normalized.x == 0)
    #expect(pad.leftStick.normalized.y == 0)
    #expect(pad.motion.isIdle)
  }

  @Test("Rejects a datagram from something other than a DSU server")
  func rejectsForeignMagic() {
    var fixture = DSUPacketFixture()
    fixture.magic = Array("HTTP".utf8)

    #expect(throws: DSUDecodingError.unexpectedMagic) {
      try DSUProtocol.decode(fixture.data())
    }
  }

  @Test("Rejects a corrupted datagram")
  func rejectsBadChecksum() {
    var bytes = [UInt8](DSUPacketFixture().data())
    bytes[24] ^= 0xFF

    #expect(throws: DSUDecodingError.checksumMismatch) {
      try DSUProtocol.decode(Data(bytes))
    }
  }

  @Test("Rejects a truncated datagram")
  func rejectsTruncatedPacket() {
    let bytes = [UInt8](DSUPacketFixture().data()).dropLast(20)

    #expect(throws: DSUDecodingError.truncatedPayload) {
      try DSUProtocol.decode(Data(bytes))
    }
  }

  @Test("Rejects a datagram claiming a newer protocol")
  func rejectsNewerVersion() {
    var fixture = DSUPacketFixture()
    fixture.version = 2_000

    #expect(throws: DSUDecodingError.unsupportedVersion(2_000)) {
      try DSUProtocol.decode(fixture.data())
    }
  }

  @Test("Ignores a message type it does not implement")
  func rejectsUnknownMessage() {
    var fixture = DSUPacketFixture()
    fixture.messageType = 0x0011_0001

    #expect(throws: DSUDecodingError.unsupportedMessage(0x0011_0001)) {
      try DSUProtocol.decode(fixture.data())
    }
  }

  @Test("Round-trips the face-button layout preference")
  func readsLayoutPreference() throws {
    let defaults = try #require(UserDefaults(suiteName: "DSUProtocolTests.layout"))
    defaults.removePersistentDomain(forName: "DSUProtocolTests.layout")

    // Nothing stored yet, so a DSU pad is read as a DualShock.
    #expect(DSUPreferences.layout(from: defaults) == .standard)

    defaults.set(
      ControllerFaceButtonLayout.nintendo.rawValue,
      forKey: DSUPreferences.layoutKey
    )
    #expect(DSUPreferences.layout(from: defaults) == .nintendo)

    defaults.set("gibberish", forKey: DSUPreferences.layoutKey)
    #expect(DSUPreferences.layout(from: defaults) == .standard)
    defaults.removePersistentDomain(forName: "DSUProtocolTests.layout")
  }

  @Test("Decodes a controller info response")
  func decodesControllerInfo() throws {
    var fixture = DSUPacketFixture(slot: 3)
    fixture.messageType = 0x0010_0001
    // The 11-byte descriptor and its terminator, plus the message type.
    fixture.payloadLength = 16

    guard case let .controllerInfo(descriptor) = try DSUProtocol.decode(fixture.data())
    else {
      Issue.record("Expected controller info.")
      return
    }

    #expect(descriptor.slot == 3)
    #expect(descriptor.isRegistered)
    #expect(descriptor.battery == 5)
  }
}

/// Builds the datagrams a DSU server would send, so decoding is exercised
/// without depending on OpenVault's own encoder.
private struct DSUPacketFixture {
  var magic = Array("DSUS".utf8)
  var version: UInt16 = 1_001
  var serverID: UInt32 = 0xDEAD_BEEF
  var messageType: UInt32 = 0x0010_0002
  var payloadLength: Int?

  var slot: UInt8 = 0
  var firstMask: UInt8 = 0
  var secondMask: UInt8 = 0
  var leftStick: (UInt8, UInt8) = (128, 128)
  var rightStick: (UInt8, UInt8) = (128, 128)
  var touch: (id: UInt8, x: UInt16, y: UInt16)?
  var motion: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)

  init(
    slot: UInt8 = 0,
    firstMask: UInt8 = 0,
    secondMask: UInt8 = 0,
    leftStick: (UInt8, UInt8) = (128, 128),
    rightStick: (UInt8, UInt8) = (128, 128),
    touch: (id: UInt8, x: UInt16, y: UInt16)? = nil,
    motion: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)
  ) {
    self.slot = slot
    self.firstMask = firstMask
    self.secondMask = secondMask
    self.leftStick = leftStick
    self.rightStick = rightStick
    self.touch = touch
    self.motion = motion
  }

  func data() -> Data {
    var payload = [UInt8](repeating: 0, count: 80)
    payload[0] = slot
    payload[1] = 2  // Connected.
    payload[2] = 2  // Full gyro.
    payload[3] = 2  // Bluetooth.
    payload[10] = 5  // Full battery.
    payload[11] = 1
    payload[16] = firstMask
    payload[17] = secondMask
    payload[20] = leftStick.0
    payload[21] = leftStick.1
    payload[22] = rightStick.0
    payload[23] = rightStick.1

    if let touch {
      payload[36] = 1
      payload[37] = touch.id
      write(UInt16(touch.x), to: &payload, at: 38)
      write(UInt16(touch.y), to: &payload, at: 40)
    }

    write(UInt64(1_234), to: &payload, at: 48)
    write(motion.0.bitPattern, to: &payload, at: 56)
    write(motion.1.bitPattern, to: &payload, at: 60)
    write(motion.2.bitPattern, to: &payload, at: 64)
    write(motion.3.bitPattern, to: &payload, at: 68)
    write(motion.4.bitPattern, to: &payload, at: 72)
    write(motion.5.bitPattern, to: &payload, at: 76)

    let declaredLength = payloadLength ?? (4 + payload.count)
    var bytes = magic
    bytes.append(contentsOf: littleEndian(version))
    bytes.append(contentsOf: littleEndian(UInt16(declaredLength)))
    bytes.append(contentsOf: [0, 0, 0, 0])
    bytes.append(contentsOf: littleEndian(serverID))
    bytes.append(contentsOf: littleEndian(messageType))
    bytes.append(contentsOf: payload)
    // A server sizes the datagram to what it declares.
    bytes.removeLast(max(0, bytes.count - (16 + declaredLength)))

    let checksum = DSUChecksum.crc32(bytes)
    bytes.replaceSubrange(8..<12, with: littleEndian(checksum))
    return Data(bytes)
  }

  private func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
  }

  private func write<Value: FixedWidthInteger>(
    _ value: Value,
    to bytes: inout [UInt8],
    at offset: Int
  ) {
    bytes.replaceSubrange(
      offset..<(offset + MemoryLayout<Value>.size),
      with: littleEndian(value)
    )
  }
}
