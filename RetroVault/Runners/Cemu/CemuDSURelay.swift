@preconcurrency import GameController
import Foundation
import Network

/// Publishes RetroVault's active controller as a local DSU pad for Cemu.
///
/// Cemu only needs to understand one stable Wii U Pro Controller profile.
/// RetroVault can then feed that profile from either its configured DSU bridge
/// or a controller macOS exposes through GameController.
final class CemuDSURelay: @unchecked Sendable {
  private static let packetInterval = DispatchTimeInterval.nanoseconds(8_333_333)
  private static let subscriptionTimeoutNanoseconds: UInt64 = 5_000_000_000

  private final class Client: @unchecked Sendable {
    let connection: NWConnection
    var subscribedSlots: Set<UInt8> = []
    var subscribesToAllSlots = false
    var lastRequestNanoseconds = DispatchTime.now().uptimeNanoseconds

    init(connection: NWConnection) {
      self.connection = connection
    }

    var wantsControllerData: Bool {
      subscribesToAllSlots || subscribedSlots.contains(0)
    }
  }

  private let queue = DispatchQueue(
    label: "org.kennethreitz.RetroVault.CemuDSURelay",
    qos: .userInteractive
  )
  private let startupLock = NSLock()
  private let startupSemaphore = DispatchSemaphore(value: 0)
  private let serverID = UInt32.random(in: 1...UInt32.max)
  private let padProvider: (@Sendable () -> DSUPadState?)?

  private var startupResult: Result<UInt16, Error>?
  private var listener: NWListener?
  private var clients: [ObjectIdentifier: Client] = [:]
  private var timer: DispatchSourceTimer?
  private var packetNumber: UInt32 = 0
  private var selectedNativeController: GCController?
  private var lastPublishedConnectionState: Bool?

  init(padProvider: (@Sendable () -> DSUPadState?)? = nil) {
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
      timer?.cancel()
      timer = nil
      for client in clients.values {
        client.connection.cancel()
      }
      clients.removeAll()
      listener?.cancel()
      listener = nil
      selectedNativeController = nil
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
        let currentPad = controllerState()
        for slot in slots {
          let isActive = slot == 0 && currentPad?.isConnected == true
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
        client.subscribesToAllSlots = false
        client.subscribedSlots.removeAll()
        continue
      }
      publishControllerData(to: client)
    }
  }

  private func publishControllerData(to client: Client) {
    guard client.wantsControllerData else { return }
    var state = controllerState() ?? Self.disconnectedState
    packetNumber &+= 1
    state.packetNumber = packetNumber
    state.descriptor.slot = 0
    state.descriptor.isRegistered = state.isConnected

    if lastPublishedConnectionState != state.isConnected {
      lastPublishedConnectionState = state.isConnected
      let source = state.isConnected
        ? (DSUConnection.shared.currentPad() != nil ? "DSU" : "GameController")
        : "none"
      RetroVaultLog.cemu.notice(
        "Cemu controller relay source: \(source, privacy: .public)"
      )
    }

    send(
      DSUProtocol.controllerDataResponse(
        state: state,
        publishedSlot: 0,
        serverID: serverID
      ),
      to: client
    )
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
    clients.removeValue(forKey: key)
    connection.cancel()
  }

  private func controllerState() -> DSUPadState? {
    if let padProvider {
      return padProvider()
    }
    if let pad = DSUConnection.shared.currentPad(), pad.isConnected {
      return pad
    }

    let connectedControllers = GCController.controllers()
    if let selectedController = selectedNativeController,
      !connectedControllers.contains(where: { $0 === selectedController })
    {
      selectedNativeController = nil
    }
    if selectedNativeController == nil {
      selectedNativeController = GCController.current
        ?? connectedControllers.first { $0.extendedGamepad != nil }
    }
    guard let controller = selectedNativeController else {
      return nil
    }
    return Self.nativeState(from: controller)
  }

  private static func nativeState(from controller: GCController) -> DSUPadState? {
    guard let gamepad = controller.extendedGamepad else { return nil }
    let layout = ControllerFaceButtonLayout.resolve(
      vendorName: controller.vendorName,
      productCategory: controller.productCategory
    )
    var buttons: DSUButtons = []
    buttons.set(.up, when: gamepad.dpad.up.isPressed)
    buttons.set(.down, when: gamepad.dpad.down.isPressed)
    buttons.set(.left, when: gamepad.dpad.left.isPressed)
    buttons.set(.right, when: gamepad.dpad.right.isPressed)
    buttons.set(.l1, when: gamepad.leftShoulder.isPressed)
    buttons.set(.r1, when: gamepad.rightShoulder.isPressed)
    buttons.set(.l2, when: gamepad.leftTrigger.isPressed)
    buttons.set(.r2, when: gamepad.rightTrigger.isPressed)
    buttons.set(.share, when: gamepad.buttonOptions?.isPressed == true)
    buttons.set(.options, when: gamepad.buttonMenu.isPressed)
    buttons.set(.leftStick, when: gamepad.leftThumbstickButton?.isPressed == true)
    buttons.set(.rightStick, when: gamepad.rightThumbstickButton?.isPressed == true)

    switch layout {
    case .standard:
      buttons.set(.a, when: gamepad.buttonA.isPressed)
      buttons.set(.b, when: gamepad.buttonB.isPressed)
      buttons.set(.x, when: gamepad.buttonX.isPressed)
      buttons.set(.y, when: gamepad.buttonY.isPressed)
    case .nintendo:
      buttons.set(.b, when: gamepad.buttonA.isPressed)
      buttons.set(.a, when: gamepad.buttonB.isPressed)
      buttons.set(.y, when: gamepad.buttonX.isPressed)
      buttons.set(.x, when: gamepad.buttonY.isPressed)
    }

    return DSUPadState(
      descriptor: DSUSlotDescriptor(
        slot: 0,
        isRegistered: true,
        // The DSU descriptor's so-called model byte is the DualShock model,
        // not a promise that motion samples are present. Cemu expects a DS4.
        gyroModel: .full,
        connectionType: 2,
        macAddress: 0x52_56_43_45_4D_55,
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
    if clamped >= 0 {
      return UInt8(clamping: 128 + Int((clamped * 127).rounded()))
    }
    return UInt8(clamping: 128 + Int((clamped * 128).rounded()))
  }

  private static func disconnectedDescriptor(slot: UInt8) -> DSUSlotDescriptor {
    DSUSlotDescriptor(slot: slot)
  }

  private static let disconnectedState = DSUPadState(
    descriptor: disconnectedDescriptor(slot: 0)
  )
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

private extension DSUButtons {
  mutating func set(_ button: DSUButtons, when condition: Bool) {
    if condition {
      insert(button)
    }
  }
}
