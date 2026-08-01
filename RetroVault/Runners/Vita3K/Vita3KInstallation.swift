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
}

enum Vita3KBridgeError: LocalizedError {
  case unavailable
  case incompatible
  case initializationFailed(String?)
  case firmwareMissing
  case firmwareInstallFailed(String)
  case archiveInstallFailed(String)
  case launchFailed(String)

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
    case .archiveInstallFailed(let message), .launchFailed(let message):
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
}
