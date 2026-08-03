@preconcurrency import AppKit
import Foundation
import Darwin

/// Locates the optional Vita3K engine used by RetroVault's experimental Vita
/// runner. The engine is loaded at runtime so normal RetroVault builds remain
/// independent of Vita3K and continue to work when it is not bundled.
struct Vita3KInstallation: Sendable {
  static let systemName = "PlayStation Vita"

  let libraryURL: URL
  let assetsURL: URL

  static var bundled: Vita3KInstallation? {
    guard
      let plugInsURL = Bundle.main.builtInPlugInsURL,
      let resourcesURL = Bundle.main.resourceURL
    else {
      return nil
    }

    let libraryURL =
      plugInsURL
      .appending(path: "Vita3K", directoryHint: .isDirectory)
      .appending(path: "RetroVaultVita3K.dylib")
    let assetsURL = resourcesURL.appending(
      path: "Vita3K",
      directoryHint: .isDirectory
    )
    guard
      FileManager.default.fileExists(atPath: libraryURL.path),
      FileManager.default.fileExists(atPath: assetsURL.path)
    else {
      return nil
    }
    return Vita3KInstallation(libraryURL: libraryURL, assetsURL: assetsURL)
  }

  static func supports(
    systemName: String,
    includingExperimental: Bool
  ) -> Bool {
    includingExperimental
      && systemName == Self.systemName
      && bundled != nil
  }
}

struct Vita3KRunRequest: Hashable, Sendable {
  let gameID: Int
  let title: String
  let archiveURL: URL
  let firmwareURLs: [URL]
  let firmwarePreparationError: String?
  let saveSync: CartridgeSaveSyncConfiguration?
}

enum Vita3KBridgeError: LocalizedError {
  case unavailable
  case incompatible
  case initializationFailed(String?)
  case firmwareMissing
  case firmwareInstallFailed(String)
  case archiveInstallFailed(String)
  case launchFailed(String)
  case invalidSaveBundle(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "The experimental Vita3K engine is not bundled in this build."
    case .incompatible:
      "The bundled Vita3K engine is incompatible with this RetroVault build."
    case .initializationFailed(let message):
      message ?? "Vita3K could not initialize its private Vita environment."
    case .firmwareMissing:
      "The main Vita firmware is required. Upload its .PUP package as system firmware in RomM, then try again."
    case .firmwareInstallFailed(let message):
      message
    case .archiveInstallFailed(let message), .launchFailed(let message),
      .invalidSaveBundle(let message):
      message
    }
  }
}

struct Vita3KFirmwareState: Equatable, Sendable {
  let hasPreinstalledPackage: Bool
  let hasMainFirmware: Bool
  let hasFontPackage: Bool

  init(mask: Int32) {
    hasPreinstalledPackage = mask & 0b001 != 0
    hasMainFirmware = mask & 0b010 != 0
    hasFontPackage = mask & 0b100 != 0
  }

  /// Vita3K permits games to launch once the main firmware is present. Its
  /// font package improves compatibility but is not a launch prerequisite.
  var canLaunch: Bool {
    hasMainFirmware
  }
}

/// A PlayStation TV actuator request expanded to the 16-bit motor strengths
/// used by RetroVault's shared DSU and native-controller output pipeline.
struct Vita3KRumbleState: Equatable, Sendable {
  let strong: UInt16
  let weak: UInt16

  init(packed: UInt32) {
    let largeMotor = UInt16((packed >> 8) & 0xFF)
    let smallMotor = UInt16(packed & 0xFF)
    strong = largeMotor * 0x0101
    weak = smallMotor * 0x0101
  }

  var isActive: Bool {
    strong != 0 || weak != 0
  }
}

/// Dynamically loads the experimental Vita3K C bridge.
///
/// Vita3K is intentionally kept behind this narrow runtime boundary. The
/// bridge can later move to a helper process without changing the player UI.
final class Vita3KBridge: @unchecked Sendable {
  typealias Create = @convention(c) (
    UnsafePointer<CChar>, UnsafePointer<CChar>
  ) -> UnsafeMutableRawPointer?
  typealias CreationError = @convention(c) () -> UnsafePointer<CChar>?
  typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias FirmwareMask = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  typealias InstallFirmware = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>
  ) -> Int32
  typealias InstallArchive = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>
  ) -> Int32
  typealias InstalledTitleID = @convention(c) (
    UnsafeMutableRawPointer?
  ) -> UnsafePointer<CChar>?
  typealias Run = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32,
    UnsafePointer<CChar>
  ) -> Int32
  typealias Resize = @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32
  ) -> Void
  typealias PumpEvents = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias SetFrontTouch = @convention(c) (
    UnsafeMutableRawPointer?, Float, Float, Int32, Int32
  ) -> Void
  typealias SetController = @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, Float, Float, Float, Float
  ) -> Void
  typealias RumbleState = @convention(c) (
    UnsafeMutableRawPointer?, Int32
  ) -> UInt32
  typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias LastError = @convention(c) (
    UnsafeMutableRawPointer?
  ) -> UnsafePointer<CChar>?

  private let handle: UnsafeMutableRawPointer
  private let engine: UnsafeMutableRawPointer
  private let destroy: Destroy
  private let firmwareMaskFunction: FirmwareMask
  private let installFirmwareFunction: InstallFirmware
  private let installArchiveFunction: InstallArchive
  private let installedTitleIDFunction: InstalledTitleID
  private let runFunction: Run
  private let resizeFunction: Resize
  private let pumpEventsFunction: PumpEvents
  private let setFrontTouchFunction: SetFrontTouch
  private let setControllerFunction: SetController
  private let rumbleStateFunction: RumbleState
  private let stopFunction: Stop
  private let lastErrorFunction: LastError

  init(installation: Vita3KInstallation) throws {
    guard
      let handle = dlopen(installation.libraryURL.path, RTLD_NOW | RTLD_LOCAL)
    else {
      throw Vita3KBridgeError.unavailable
    }

    func symbol<T>(_ name: String, as _: T.Type) throws -> T {
      guard let address = dlsym(handle, name) else {
        throw Vita3KBridgeError.incompatible
      }
      return unsafeBitCast(address, to: T.self)
    }

    do {
      let create = try symbol("retrovault_vita3k_create", as: Create.self)
      let creationError = try symbol(
        "retrovault_vita3k_creation_error",
        as: CreationError.self
      )
      destroy = try symbol("retrovault_vita3k_destroy", as: Destroy.self)
      firmwareMaskFunction = try symbol(
        "retrovault_vita3k_firmware_mask",
        as: FirmwareMask.self
      )
      installFirmwareFunction = try symbol(
        "retrovault_vita3k_install_firmware",
        as: InstallFirmware.self
      )
      installArchiveFunction = try symbol(
        "retrovault_vita3k_install_archive",
        as: InstallArchive.self
      )
      installedTitleIDFunction = try symbol(
        "retrovault_vita3k_installed_title_id",
        as: InstalledTitleID.self
      )
      runFunction = try symbol("retrovault_vita3k_run", as: Run.self)
      resizeFunction = try symbol("retrovault_vita3k_resize", as: Resize.self)
      pumpEventsFunction = try symbol(
        "retrovault_vita3k_pump_events",
        as: PumpEvents.self
      )
      setFrontTouchFunction = try symbol(
        "retrovault_vita3k_set_front_touch",
        as: SetFrontTouch.self
      )
      setControllerFunction = try symbol(
        "retrovault_vita3k_set_controller",
        as: SetController.self
      )
      rumbleStateFunction = try symbol(
        "retrovault_vita3k_rumble_state",
        as: RumbleState.self
      )
      stopFunction = try symbol("retrovault_vita3k_stop", as: Stop.self)
      lastErrorFunction = try symbol(
        "retrovault_vita3k_last_error",
        as: LastError.self
      )

      let storageURL = try Self.storageURL()
      let created = storageURL.path.withCString { storagePath in
        installation.assetsURL.path.withCString { assetsPath in
          create(storagePath, assetsPath)
        }
      }
      guard let created else {
        let message = creationError().map { String(cString: $0) }
        throw Vita3KBridgeError.initializationFailed(message)
      }
      self.handle = handle
      engine = created
    } catch {
      dlclose(handle)
      throw error
    }
  }

  deinit {
    destroy(engine)
    dlclose(handle)
  }

  var firmwareState: Vita3KFirmwareState {
    // Vita3K reports preinstalled, main, and font packages as three bits.
    Vita3KFirmwareState(mask: firmwareMaskFunction(engine))
  }

  var hasRequiredFirmware: Bool {
    firmwareState.canLaunch
  }

  func installFirmware(at url: URL) throws {
    let installed = url.path.withCString {
      installFirmwareFunction(engine, $0) != 0
    }
    guard installed else {
      throw Vita3KBridgeError.firmwareInstallFailed(lastError)
    }
  }

  func installArchive(at url: URL, gameID: Int) throws -> String {
    if let cached = UserDefaults.standard.string(
      forKey: Self.titleIDKey(gameID: gameID)
    ), !cached.isEmpty {
      return cached
    }

    let installed = url.path.withCString {
      installArchiveFunction(engine, $0) != 0
    }
    guard installed,
      let pointer = installedTitleIDFunction(engine)
    else {
      throw Vita3KBridgeError.archiveInstallFailed(lastError)
    }
    let titleID = String(cString: pointer)
    guard !titleID.isEmpty else {
      throw Vita3KBridgeError.archiveInstallFailed(lastError)
    }
    UserDefaults.standard.set(titleID, forKey: Self.titleIDKey(gameID: gameID))
    return titleID
  }

  func run(in view: NSView, pixelSize: CGSize, titleID: String) throws {
    let result = titleID.withCString {
      runFunction(
        engine,
        Unmanaged.passUnretained(view).toOpaque(),
        Int32(max(1, pixelSize.width.rounded())),
        Int32(max(1, pixelSize.height.rounded())),
        $0
      )
    }
    guard result != 0 else {
      throw Vita3KBridgeError.launchFailed(lastError)
    }
  }

  func resize(to pixelSize: CGSize) {
    resizeFunction(
      engine,
      Int32(max(1, pixelSize.width.rounded())),
      Int32(max(1, pixelSize.height.rounded()))
    )
  }

  /// Pumps Vita3K's SDL events from AppKit's required main thread.
  @MainActor
  func pumpEvents() {
    pumpEventsFunction(engine)
  }

  /// Updates the primary pointer presented as the Vita's front touchscreen.
  func setFrontTouch(at point: CGPoint, pressed: Bool, active: Bool) {
    setFrontTouchFunction(
      engine,
      Float(point.x),
      Float(point.y),
      pressed ? 1 : 0,
      active ? 1 : 0
    )
  }

  /// Replaces Vita3K's virtual controller state with the latest state read by
  /// RetroVault. This keeps DSU and GameController behavior consistent with
  /// the rest of the app instead of depending on the engine's private SDL
  /// controller discovery.
  func setController(_ state: Vita3KControllerState) {
    setControllerFunction(
      engine,
      state.buttons,
      state.extendedButtons,
      state.leftX,
      state.leftY,
      state.rightX,
      state.rightY
    )
  }

  /// Reads the latest actuator request for a zero-based PlayStation TV player.
  func rumbleState(forPlayer player: Int) -> Vita3KRumbleState {
    Vita3KRumbleState(
      packed: rumbleStateFunction(engine, Int32(player))
    )
  }

  func stop() {
    stopFunction(engine)
  }

  private var lastError: String {
    guard let pointer = lastErrorFunction(engine) else {
      return "Vita3K reported an unknown error."
    }
    let message = String(cString: pointer)
    return message.isEmpty ? "Vita3K reported an unknown error." : message
  }

  private static func storageURL() throws -> URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? URL.temporaryDirectory
    let url = base
      .appending(path: "RetroVault", directoryHint: .isDirectory)
      .appending(path: "Vita3K", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private static func titleIDKey(gameID: Int) -> String {
    "vita3k.installed-title-id.\(gameID)"
  }

  /// Returns the title ID Vita3K recorded when it installed this RomM game.
  ///
  /// Save staging happens before the hosted engine starts, so it deliberately
  /// uses the stable game-to-title mapping recorded by `installArchive`.
  static func cachedTitleID(forGameID gameID: Int) -> String? {
    normalizedTitleID(
      UserDefaults.standard.string(forKey: titleIDKey(gameID: gameID))
    )
  }

  /// Captures a Vita3K save that is newer than RetroVault's managed copy.
  ///
  /// This recovery step protects sessions that ended while the app or Mac was
  /// shutting down. It also adopts saves created before hosted Vita save sync
  /// existed, without letting a zero-byte Vita3K placeholder hide a real RomM
  /// save.
  @discardableResult
  static func stageExistingSaveIfNeeded(
    gameID: Int,
    managedURL: URL,
    vitaStorageURL: URL? = nil
  ) throws -> Bool {
    guard let titleID = cachedTitleID(forGameID: gameID) else {
      return false
    }
    let liveURL = try liveSaveURL(
      titleID: titleID,
      vitaStorageURL: vitaStorageURL
    )
    guard let liveModifiedAt = latestMeaningfulModificationDate(in: liveURL) else {
      return false
    }

    let managedSource = try managedSaveSource(
      in: managedURL,
      titleID: titleID
    )
    if let managedModifiedAt = latestMeaningfulModificationDate(
      in: managedSource.url
    ), managedModifiedAt >= liveModifiedAt {
      return false
    }
    return try captureSaveData(
      to: managedURL,
      titleID: titleID,
      vitaStorageURL: vitaStorageURL
    )
  }

  /// Projects a managed RomM save into Vita3K's live savedata directory.
  ///
  /// Cannoli's portable marker + `save/` layout and RetroVault's older direct
  /// directory bundles are both accepted. The managed copy is never mutated.
  @discardableResult
  static func prepareRestoredSaveData(
    from managedURL: URL,
    titleID: String,
    vitaStorageURL: URL? = nil
  ) throws -> Bool {
    guard let titleID = normalizedTitleID(titleID) else {
      throw Vita3KBridgeError.invalidSaveBundle(
        "Vita3K reported an invalid PlayStation Vita title ID."
      )
    }
    let source = try managedSaveSource(in: managedURL, titleID: titleID)
    guard containsMeaningfulSaveData(in: source.url) else {
      return false
    }
    let destination = try liveSaveURL(
      titleID: titleID,
      vitaStorageURL: vitaStorageURL
    )
    try replaceDirectoryContents(from: source.url, to: destination)
    return true
  }

  /// Captures Vita3K's live savedata while retaining the imported RomM shape.
  ///
  /// New saves use Cannoli's portable representation so either client can
  /// consume the next revision. Existing direct bundles remain direct.
  @discardableResult
  static func captureSaveData(
    to managedURL: URL,
    titleID: String,
    vitaStorageURL: URL? = nil
  ) throws -> Bool {
    guard let titleID = normalizedTitleID(titleID) else {
      throw Vita3KBridgeError.invalidSaveBundle(
        "Vita3K reported an invalid PlayStation Vita title ID."
      )
    }
    let source = try liveSaveURL(
      titleID: titleID,
      vitaStorageURL: vitaStorageURL
    )
    guard containsMeaningfulSaveData(in: source) else {
      return false
    }

    let existing = try managedSaveSource(in: managedURL, titleID: titleID)
    let usesPortableLayout = existing.isPortable
      || !containsMeaningfulSaveData(in: existing.url)
    if usesPortableLayout {
      try FileManager.default.createDirectory(
        at: managedURL,
        withIntermediateDirectories: true
      )
      let portableURL = managedURL.appending(
        path: "save",
        directoryHint: .isDirectory
      )
      try replaceDirectoryContents(from: source, to: portableURL)
      let markerData = existing.markerData ?? portableMarkerData(titleID: titleID)
      try markerData.write(
        to: managedURL.appending(path: "cannoli-standalone-save.txt"),
        options: .atomic
      )
    } else {
      try replaceDirectoryContents(from: source, to: managedURL)
    }
    return true
  }

  private struct ManagedSaveSource {
    let url: URL
    let isPortable: Bool
    let markerData: Data?
  }

  private static func managedSaveSource(
    in managedURL: URL,
    titleID: String
  ) throws -> ManagedSaveSource {
    let markerURL = managedURL.appending(
      path: "cannoli-standalone-save.txt"
    )
    let portableURL = managedURL.appending(
      path: "save",
      directoryHint: .isDirectory
    )
    let markerData = try? Data(contentsOf: markerURL)
    let hasPortableDirectory = FileManager.default.fileExists(
      atPath: portableURL.path
    )
    guard markerData != nil || hasPortableDirectory else {
      return ManagedSaveSource(
        url: managedURL,
        isPortable: false,
        markerData: nil
      )
    }

    if let markerData {
      guard let marker = String(data: markerData, encoding: .utf8) else {
        throw Vita3KBridgeError.invalidSaveBundle(
          "The RomM Vita save marker is not valid UTF-8."
        )
      }
      var fields: [String: String] = [:]
      for line in marker.split(whereSeparator: { $0.isNewline }) {
        let components = line.split(separator: "=", maxSplits: 1)
        guard components.count == 2 else { continue }
        fields[String(components[0])] = String(components[1])
      }
      guard
        fields["emulator"]?.uppercased() == "VITA3K",
        normalizedTitleID(fields["title_id"]) == titleID
      else {
        throw Vita3KBridgeError.invalidSaveBundle(
          "The RomM Vita save belongs to a different Vita title."
        )
      }
    }
    return ManagedSaveSource(
      url: portableURL,
      isPortable: true,
      markerData: markerData
    )
  }

  private static func liveSaveURL(
    titleID: String,
    vitaStorageURL: URL?
  ) throws -> URL {
    let baseURL = try vitaStorageURL ?? storageURL()
    return baseURL
      .appending(path: "vita", directoryHint: .isDirectory)
      .appending(path: "ux0", directoryHint: .isDirectory)
      .appending(path: "user", directoryHint: .isDirectory)
      .appending(path: "00", directoryHint: .isDirectory)
      .appending(path: "savedata", directoryHint: .isDirectory)
      .appending(path: titleID, directoryHint: .isDirectory)
  }

  private static func replaceDirectoryContents(
    from sourceURL: URL,
    to destinationURL: URL
  ) throws {
    let archive = SaveBundleArchive()
    guard let data = try archive.data(from: sourceURL) else {
      throw Vita3KBridgeError.invalidSaveBundle(
        "The Vita save bundle contains no save data."
      )
    }
    let temporaryURL = FileManager.default.temporaryDirectory.appending(
      path: "RetroVault-VitaSave-\(UUID().uuidString).zip"
    )
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try data.write(to: temporaryURL, options: .atomic)
    try archive.restore(from: temporaryURL, to: destinationURL)
  }

  private static func containsMeaningfulSaveData(in directoryURL: URL) -> Bool {
    latestMeaningfulModificationDate(in: directoryURL) != nil
  }

  private static func latestMeaningfulModificationDate(
    in directoryURL: URL
  ) -> Date? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return nil
    }
    var latest: Date?
    for case let fileURL as URL in enumerator {
      guard
        fileURL.lastPathComponent != "cannoli-standalone-save.txt",
        let values = try? fileURL.resourceValues(forKeys: [
          .isRegularFileKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ]),
        values.isRegularFile == true,
        (values.fileSize ?? 0) > 0
      else {
        continue
      }
      let modifiedAt = values.contentModificationDate ?? .distantPast
      if latest.map({ modifiedAt > $0 }) ?? true {
        latest = modifiedAt
      }
    }
    return latest
  }

  private static func normalizedTitleID(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    guard
      normalized.count == 9,
      normalized.unicodeScalars.allSatisfy({ scalar in
        (65...90).contains(scalar.value)
          || (48...57).contains(scalar.value)
      })
    else {
      return nil
    }
    return normalized
  }

  private static func portableMarkerData(titleID: String) -> Data {
    Data(
      "format=1\nemulator=VITA3K\ntitle_id=\(titleID)\n".utf8
    )
  }
}
