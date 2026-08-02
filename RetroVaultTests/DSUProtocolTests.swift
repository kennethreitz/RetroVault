import Foundation
import Testing

@testable import RetroVault

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

  @Test("Decodes the requests Cemu sends to a DSU server")
  func decodesClientRequests() throws {
    #expect(
      try DSUProtocol.decodeClientRequest(
        DSUProtocol.encode(
          message: .protocolVersion,
          payload: [],
          clientID: 1
        )
      ) == .protocolVersion
    )
    #expect(
      try DSUProtocol.decodeClientRequest(
        DSUProtocol.controllerInfoRequest(clientID: 2)
      ) == .controllerInfo(slots: [0, 1, 2, 3])
    )
    #expect(
      try DSUProtocol.decodeClientRequest(
        DSUProtocol.padDataRequest(clientID: 3)
      ) == .controllerData(slot: nil)
    )
    #expect(
      try DSUProtocol.decodeClientRequest(
        DSUProtocol.motorInfoRequest(slot: 2, clientID: 4)
      ) == .motorInfo(slot: 2)
    )
    #expect(
      try DSUProtocol.decodeClientRequest(
        DSUProtocol.rumbleRequest(
          slot: 3,
          motor: 1,
          intensity: 0xA5,
          clientID: 5
        )
      ) == .rumble(slot: 3, motor: 1, intensity: 0xA5)
    )
  }

  @Test("Publishes motor capabilities through the DSU extension")
  func encodesMotorInfo() throws {
    let descriptor = DSUSlotDescriptor(
      slot: 1,
      isRegistered: true,
      connectionType: 2,
      macAddress: 0x11_22_33_44_55_66,
      battery: 5
    )
    let packet = DSUProtocol.motorInfoResponse(
      descriptor: descriptor,
      motorCount: 2,
      serverID: 7
    )
    guard case let .motorInfo(info) = try DSUProtocol.decode(packet) else {
      Issue.record("Expected motor info.")
      return
    }
    #expect(info.descriptor == descriptor)
    #expect(info.motorCount == 2)
  }

  @Test("Publishes a complete controller packet Cemu can decode")
  func encodesServerControllerData() throws {
    let state = DSUPadState(
      descriptor: DSUSlotDescriptor(
        slot: 2,
        isRegistered: true,
        gyroModel: .unavailable,
        connectionType: 2,
        macAddress: 0x11_22_33_44_55_66,
        battery: 5
      ),
      isConnected: true,
      packetNumber: 42,
      buttons: [.up, .b, .r1],
      leftStick: DSUStick(x: 0, y: 255),
      rightStick: DSUStick(x: 200, y: 100)
    )
    let response = DSUProtocol.controllerDataResponse(
      state: state,
      publishedSlot: 0,
      serverID: 0x1234_5678
    )

    #expect(response.count == 100)
    guard case let .controllerData(decoded) = try DSUProtocol.decode(response) else {
      Issue.record("Expected controller data.")
      return
    }
    #expect(decoded.slot == 0)
    #expect(decoded.isConnected)
    #expect(decoded.packetNumber == 42)
    #expect(decoded.buttons.contains(.up))
    #expect(decoded.buttons.contains(.b))
    #expect(decoded.buttons.contains(.r1))
    #expect(decoded.leftStick == DSUStick(x: 0, y: 255))
    #expect(decoded.rightStick == DSUStick(x: 200, y: 100))
  }

  @Test("Relays controller state over a real local DSU connection")
  func relaysControllerState() async throws {
    let state = DSUPadState(
      descriptor: DSUSlotDescriptor(
        slot: 0,
        isRegistered: true,
        gyroModel: .unavailable,
        connectionType: 2,
        macAddress: 0x11_22_33_44_55_66,
        battery: 5
      ),
      isConnected: true,
      buttons: [.right, .b],
      leftStick: DSUStick(x: 220, y: 90)
    )
    let relay = CemuDSURelay { slot in
      RoutedDSUPad(
        state: state,
        layout: .nintendo,
        source: .network(remoteSlot: slot)
      )
    }
    let port = try await Task.detached {
      try relay.start()
    }.value
    let client = DSUClient(
      configuration: DSUConfiguration(
        host: "127.0.0.1",
        port: port
      )
    )
    client.start()
    defer {
      client.stop()
      relay.stop()
    }

    var received: DSUPadState?
    for _ in 0..<100 where received == nil {
      try await Task.sleep(for: .milliseconds(10))
      received = client.currentPads().first
    }

    let pad = try #require(received)
    #expect(pad.isConnected)
    #expect(pad.buttons.contains(.right))
    #expect(pad.buttons.contains(.b))
    #expect(pad.leftStick == DSUStick(x: 220, y: 90))
  }

  @Test("Relays strong and weak motor output over a real DSU connection")
  func relaysRumble() async throws {
    let state = DSUPadState(
      descriptor: DSUSlotDescriptor(slot: 0, isRegistered: true),
      isConnected: true
    )
    let capture = DSURumbleCapture()
    let relay = CemuDSURelay(
      rumbleHandler: { slot, strong, weak in
        capture.record(slot: slot, strong: strong, weak: weak)
        return true
      },
      padProvider: { slot in
        RoutedDSUPad(
          state: state,
          layout: .nintendo,
          source: .network(remoteSlot: slot)
        )
      }
    )
    let port = try await Task.detached {
      try relay.start()
    }.value
    let client = DSUClient(
      configuration: DSUConfiguration(host: "127.0.0.1", port: port)
    )
    client.start()
    defer {
      client.stop()
      relay.stop()
    }

    for _ in 0..<100 where client.currentPads().isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(client.setRumble(slot: 0, strong: 0x8080, weak: 0x4040))

    var effect: DSURumbleCapture.Effect?
    for _ in 0..<100 where effect?.weak != 0x4040 {
      try await Task.sleep(for: .milliseconds(10))
      effect = capture.latest
    }
    #expect(effect == .init(slot: 0, strong: 0x8080, weak: 0x4040))
  }

  @Test("Relays multiple controller slots over one DSU server")
  func relaysMultipleControllerSlots() async throws {
    let first = DSUPadState(
      descriptor: DSUSlotDescriptor(slot: 0, isRegistered: true),
      isConnected: true,
      buttons: [.a]
    )
    let second = DSUPadState(
      descriptor: DSUSlotDescriptor(slot: 1, isRegistered: true),
      isConnected: true,
      buttons: [.b],
      rightStick: DSUStick(x: 40, y: 210)
    )
    let relay = CemuDSURelay { slot in
      switch slot {
      case 0:
        RoutedDSUPad(
          state: first,
          layout: .nintendo,
          source: .network(remoteSlot: slot)
        )
      case 1:
        RoutedDSUPad(
          state: second,
          layout: .nintendo,
          source: .network(remoteSlot: slot)
        )
      default: nil
      }
    }
    let port = try await Task.detached {
      try relay.start()
    }.value
    let client = DSUClient(
      configuration: DSUConfiguration(
        host: "127.0.0.1",
        port: port
      )
    )
    client.start()
    defer {
      client.stop()
      relay.stop()
    }

    var received: [DSUPadState] = []
    for _ in 0..<100 where received.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
      received = client.currentPads()
    }

    let firstPad = try #require(received.first(where: { $0.slot == 0 }))
    let secondPad = try #require(received.first(where: { $0.slot == 1 }))
    #expect(firstPad.slot == 0)
    #expect(firstPad.buttons.contains(.a))
    #expect(secondPad.slot == 1)
    #expect(secondPad.buttons.contains(.b))
    #expect(secondPad.rightStick == DSUStick(x: 40, y: 210))
  }

  @Test("Normalizes standard-layout face buttons for Cemu")
  func normalizesStandardFaceButtons() async throws {
    let state = DSUPadState(
      descriptor: DSUSlotDescriptor(slot: 0, isRegistered: true),
      isConnected: true,
      buttons: [.b, .y]
    )
    let relay = CemuDSURelay { slot in
      RoutedDSUPad(
        state: state,
        layout: .standard,
        source: .network(remoteSlot: slot)
      )
    }
    let port = try await Task.detached {
      try relay.start()
    }.value
    let client = DSUClient(
      configuration: DSUConfiguration(host: "127.0.0.1", port: port)
    )
    client.start()
    defer {
      client.stop()
      relay.stop()
    }

    var received: DSUPadState?
    for _ in 0..<100 where received == nil {
      try await Task.sleep(for: .milliseconds(10))
      received = client.currentPads().first
    }

    let pad = try #require(received)
    #expect(pad.buttons.contains(.a))
    #expect(pad.buttons.contains(.x))
    #expect(!pad.buttons.contains(.b))
    #expect(!pad.buttons.contains(.y))
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
    fixture.messageType = 0x00FF_FFFE

    #expect(throws: DSUDecodingError.unsupportedMessage(0x00FF_FFFE)) {
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

private final class DSURumbleCapture: @unchecked Sendable {
  struct Effect: Equatable, Sendable {
    let slot: UInt8
    let strong: UInt16
    let weak: UInt16
  }

  private let lock = NSLock()
  private var stored: Effect?

  var latest: Effect? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func record(slot: UInt8, strong: UInt16, weak: UInt16) {
    lock.lock()
    stored = Effect(slot: slot, strong: strong, weak: weak)
    lock.unlock()
  }
}

/// Builds the datagrams a DSU server would send, so decoding is exercised
/// without depending on RetroVault's own encoder.
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
