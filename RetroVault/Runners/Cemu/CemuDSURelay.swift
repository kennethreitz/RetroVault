import Foundation
import Network

/// Publishes RetroVault's active controllers as local DSU pads for Cemu.
///
/// Cemu receives four stable Wii U Pro Controller slots. Network DSU pads keep
/// their published player numbers, and controllers exposed through
/// GameController fill the vacant slots.
final class CemuDSURelay: @unchecked Sendable {
  private static let packetInterval = DispatchTimeInterval.nanoseconds(8_333_333)
  private static let subscriptionTimeoutNanoseconds: UInt64 = 5_000_000_000

  private final class Client: @unchecked Sendable {
    let connection: NWConnection
    var subscribedSlots: Set<UInt8> = []
    var subscribesToAllSlots = false
    var rumblingSlots: Set<UInt8> = []
    var lastRequestNanoseconds = DispatchTime.now().uptimeNanoseconds

    init(connection: NWConnection) {
      self.connection = connection
    }

    var wantsControllerData: Bool {
      subscribesToAllSlots || !subscribedSlots.isEmpty
    }

    func wantsControllerData(for slot: UInt8) -> Bool {
      subscribesToAllSlots || subscribedSlots.contains(slot)
    }
  }

  private let queue = DispatchQueue(
    label: "org.kennethreitz.RetroVault.CemuDSURelay",
    qos: .userInteractive
  )
  private let startupLock = NSLock()
  private let startupSemaphore = DispatchSemaphore(value: 0)
  private let serverID = UInt32.random(in: 1...UInt32.max)
  private let rumbleHandler: (@Sendable (UInt8, UInt16, UInt16) -> Bool)?
  private let padProvider: (@Sendable (UInt8) -> RoutedDSUPad?)?

  private var startupResult: Result<UInt16, Error>?
  private var listener: NWListener?
  private var clients: [ObjectIdentifier: Client] = [:]
  private var timer: DispatchSourceTimer?
  private var packetNumbers = Array(
    repeating: UInt32(0),
    count: Int(DSUProtocol.slotCount)
  )
  private var lastPublishedConnectionStates = Array<Bool?>(
    repeating: nil,
    count: Int(DSUProtocol.slotCount)
  )
  private var rumble = Array(
    repeating: (strong: UInt8(0), weak: UInt8(0)),
    count: Int(DSUProtocol.slotCount)
  )

  init(padProvider: (@Sendable (UInt8) -> RoutedDSUPad?)? = nil) {
    rumbleHandler = nil
    self.padProvider = padProvider
  }

  init(
    rumbleHandler: @escaping @Sendable (UInt8, UInt16, UInt16) -> Bool,
    padProvider: (@Sendable (UInt8) -> RoutedDSUPad?)? = nil
  ) {
    self.rumbleHandler = rumbleHandler
    self.padProvider = padProvider
  }

  /// Starts a localhost-only DSU server and waits until its UDP port is bound.
  /// Call this away from the main actor because startup waits for Network.framework.
  func start() throws -> UInt16 {
    let parameters = NWParameters.udp
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: .any)
    self.listener = listener

    listener.stateUpdateHandler = { [weak self] state in
      self?.handleListenerState(state)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)

    guard startupSemaphore.wait(timeout: .now() + 2) == .success else {
      listener.cancel()
      throw CemuDSURelayError.startupTimedOut
    }

    startupLock.lock()
    let result = startupResult
    startupLock.unlock()
    guard let result else {
      listener.cancel()
      throw CemuDSURelayError.startupTimedOut
    }
    return try result.get()
  }

  func stop() {
    queue.async { [self] in
      stopAllRumble()
      timer?.cancel()
      timer = nil
      for client in clients.values {
        client.connection.cancel()
      }
      clients.removeAll()
      listener?.cancel()
      listener = nil
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let port = listener?.port?.rawValue else {
        completeStartup(.failure(CemuDSURelayError.missingPort))
        return
      }
      beginPublishing()
      completeStartup(.success(port))
      RetroVaultLog.cemu.notice(
        "Cemu controller relay listening on 127.0.0.1:\(port, privacy: .public)"
      )
    case .failed(let error):
      completeStartup(.failure(error))
      RetroVaultLog.cemu.error(
        "Cemu controller relay failed: \(error.localizedDescription, privacy: .public)"
      )
    case .cancelled:
      completeStartup(.failure(CemuDSURelayError.cancelled))
    default:
      break
    }
  }

  private func completeStartup(_ result: Result<UInt16, Error>) {
    startupLock.lock()
    guard startupResult == nil else {
      startupLock.unlock()
      return
    }
    startupResult = result
    startupLock.unlock()
    startupSemaphore.signal()
  }

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    let client = Client(connection: connection)
    clients[key] = client
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      if case .failed = state {
        remove(connection)
      } else if case .cancelled = state {
        remove(connection)
      }
    }
    connection.start(queue: queue)
    receive(on: client)
  }

  private func receive(on client: Client) {
    client.connection.receiveMessage { [weak self, weak client] data, _, _, error in
      guard let self, let client else { return }
      if let data {
        handle(data, from: client)
      }
      if error == nil {
        receive(on: client)
      } else {
        remove(client.connection)
      }
    }
  }

  private func handle(_ datagram: Data, from client: Client) {
    do {
      client.lastRequestNanoseconds = DispatchTime.now().uptimeNanoseconds
      switch try DSUProtocol.decodeClientRequest(datagram) {
      case .protocolVersion:
        send(DSUProtocol.protocolVersionResponse(serverID: serverID), to: client)
      case .controllerInfo(let slots):
        let currentPads = controllerStates()
        for slot in slots {
          let currentPad = currentPads[safe: Int(slot)] ?? nil
          let isActive = currentPad?.isConnected == true
          var descriptor = isActive
            ? currentPad?.descriptor ?? Self.disconnectedDescriptor(slot: slot)
            : Self.disconnectedDescriptor(slot: slot)
          descriptor.slot = slot
          send(
            DSUProtocol.controllerInfoResponse(
              descriptor: descriptor,
              isActive: isActive,
              serverID: serverID
            ),
            to: client
          )
        }
      case .controllerData(let slot):
        let wasSubscribed = client.wantsControllerData
        client.subscribesToAllSlots = slot == nil
        if let slot {
          client.subscribedSlots.insert(slot)
        }
        if !wasSubscribed, client.wantsControllerData {
          RetroVaultLog.cemu.notice(
            "Cemu subscribed to RetroVault controller input"
          )
        }
      case .motorInfo(let requestedSlot):
        let slot = requestedSlot ?? 0
        let currentPad = controllerStates()[safe: Int(slot)] ?? nil
        var descriptor = currentPad?.descriptor
          ?? Self.disconnectedDescriptor(slot: slot)
        descriptor.slot = slot
        send(
          DSUProtocol.motorInfoResponse(
            descriptor: descriptor,
            motorCount: currentPad?.isConnected == true ? 2 : 0,
            serverID: serverID
          ),
          to: client
        )
      case let .rumble(requestedSlot, motor, intensity):
        guard let slot = requestedSlot, slot < DSUProtocol.slotCount else {
          break
        }
        client.rumblingSlots.insert(slot)
        applyRumble(slot: slot, motor: motor, intensity: intensity)
        let effect = rumble[Int(slot)]
        if effect.strong == 0, effect.weak == 0 {
          client.rumblingSlots.remove(slot)
        }
      }
    } catch {
      RetroVaultLog.cemu.debug(
        "Ignored invalid Cemu DSU request: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func beginPublishing() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now(),
      repeating: Self.packetInterval,
      leeway: .milliseconds(1)
    )
    timer.setEventHandler { [weak self] in
      self?.publishControllerData()
    }
    self.timer = timer
    timer.activate()
  }

  private func publishControllerData() {
    let now = DispatchTime.now().uptimeNanoseconds
    for client in clients.values where client.wantsControllerData {
      guard now &- client.lastRequestNanoseconds < Self.subscriptionTimeoutNanoseconds else {
        stopRumble(for: client.rumblingSlots)
        client.rumblingSlots.removeAll()
        client.subscribesToAllSlots = false
        client.subscribedSlots.removeAll()
        continue
      }
      publishControllerData(to: client)
    }
  }

  private func publishControllerData(to client: Client) {
    guard client.wantsControllerData else { return }
    let states = controllerStates()
    for rawSlot in 0..<DSUProtocol.slotCount {
      guard client.wantsControllerData(for: rawSlot) else { continue }
      let slot = Int(rawSlot)
      var state = states[slot] ?? Self.disconnectedState(for: rawSlot)
      packetNumbers[slot] &+= 1
      state.packetNumber = packetNumbers[slot]
      state.descriptor.slot = rawSlot
      state.descriptor.isRegistered = state.isConnected

      if lastPublishedConnectionStates[slot] != state.isConnected {
        lastPublishedConnectionStates[slot] = state.isConnected
        let source: String
        if !state.isConnected {
          source = "none"
        } else {
          source = "controller hub"
        }
        RetroVaultLog.cemu.notice(
          "Cemu controller relay player \(slot + 1, privacy: .public) source: \(source, privacy: .public)"
        )
      }

      send(
        DSUProtocol.controllerDataResponse(
          state: state,
          publishedSlot: rawSlot,
          serverID: serverID
        ),
        to: client
      )
    }
  }

  private func send(_ data: Data, to client: Client) {
    client.connection.send(
      content: data,
      completion: .contentProcessed { [weak self, weak client] error in
        guard let self, let client, error != nil else { return }
        remove(client.connection)
      }
    )
  }

  private func remove(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    if let client = clients.removeValue(forKey: key) {
      stopRumble(for: client.rumblingSlots)
    }
    connection.cancel()
  }

  private func applyRumble(slot: UInt8, motor: UInt8, intensity: UInt8) {
    let index = Int(slot)
    guard rumble.indices.contains(index) else { return }
    switch motor {
    case 0:
      rumble[index].strong = intensity
    case 1:
      rumble[index].weak = intensity
    default:
      return
    }
    let effect = rumble[index]
    let strong = UInt16(effect.strong) * 257
    let weak = UInt16(effect.weak) * 257
    if let rumbleHandler {
      _ = rumbleHandler(slot, strong, weak)
    } else {
      _ = DSUConnection.shared.setRumble(
        slot: slot,
        strong: strong,
        weak: weak
      )
    }
  }

  private func stopRumble(for slots: Set<UInt8>) {
    for slot in slots where slot < DSUProtocol.slotCount {
      let index = Int(slot)
      rumble[index] = (0, 0)
      if let rumbleHandler {
        _ = rumbleHandler(slot, 0, 0)
      } else {
        _ = DSUConnection.shared.setRumble(slot: slot, strong: 0, weak: 0)
      }
    }
  }

  private func stopAllRumble() {
    stopRumble(for: Set(0..<DSUProtocol.slotCount))
  }

  private func controllerStates() -> [DSUPadState?] {
    var states = Array<DSUPadState?>(
      repeating: nil,
      count: Int(DSUProtocol.slotCount)
    )
    let routedPads: [RoutedDSUPad]
    if let padProvider {
      routedPads = (0..<DSUProtocol.slotCount).compactMap(padProvider)
    } else {
      routedPads = DSUConnection.shared.currentPads()
    }
    for routedPad in routedPads {
      var state = routedPad.state
      state.buttons = Self.cemuButtons(
        state.buttons,
        layout: routedPad.layout
      )
      let slot = Int(state.slot)
      guard states.indices.contains(slot) else { continue }
      states[slot] = state
    }
    return states
  }

  private static func cemuButtons(
    _ buttons: DSUButtons,
    layout: ControllerFaceButtonLayout
  ) -> DSUButtons {
    // Cemu's profile is semantic Nintendo layout: A and X are the Nintendo
    // labels, not the south and west physical positions. Nintendo controllers
    // already publish those labels directly; standard-layout controllers need
    // their face buttons swapped so physical positions remain conventional.
    guard layout == .standard else { return buttons }
    var normalized = buttons
    normalized.subtract([.a, .b, .x, .y])
    if buttons.contains(.a) { normalized.insert(.b) }
    if buttons.contains(.b) { normalized.insert(.a) }
    if buttons.contains(.x) { normalized.insert(.y) }
    if buttons.contains(.y) { normalized.insert(.x) }
    return normalized
  }

  private static func disconnectedDescriptor(slot: UInt8) -> DSUSlotDescriptor {
    DSUSlotDescriptor(slot: slot)
  }

  private static func disconnectedState(for slot: UInt8) -> DSUPadState {
    DSUPadState(descriptor: disconnectedDescriptor(slot: slot))
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private enum CemuDSURelayError: LocalizedError {
  case startupTimedOut
  case missingPort
  case cancelled

  var errorDescription: String? {
    switch self {
    case .startupTimedOut:
      "RetroVault's Cemu controller relay did not start in time."
    case .missingPort:
      "RetroVault's Cemu controller relay did not receive a UDP port."
    case .cancelled:
      "RetroVault's Cemu controller relay was cancelled."
    }
  }
}
