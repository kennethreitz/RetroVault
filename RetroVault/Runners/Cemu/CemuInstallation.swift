import Foundation

/// Locates and prepares the Cemu companion application used for Wii U games.
///
/// Cemu is a standalone emulator rather than a Libretro core. RetroVault keeps
/// a private portable copy so Cemu's configuration, shader cache, and logs do
/// not leak into or depend on a user's separate Cemu installation.
struct CemuInstallation: Sendable {
  static let systemName = "Wii U"
  static let supportedFileExtensions = ["wua", "wux", "wud", "rpx"]
  let sourceApplicationURL: URL
  let applicationSupportURL: URL
  let cemuUserDataURL: URL
  let processHomeURL: URL

  static var available: CemuInstallation? {
    guard let sourceApplicationURL else {
      return nil
    }
    return CemuInstallation(
      sourceApplicationURL: sourceApplicationURL,
      applicationSupportURL: defaultApplicationSupportURL,
      cemuUserDataURL: defaultCemuUserDataURL,
      processHomeURL: defaultProcessHomeURL
    )
  }

  static func supports(systemName: String) -> Bool {
    systemName.caseInsensitiveCompare(Self.systemName) == .orderedSame
      && available != nil
  }

  private static var sourceApplicationURL: URL? {
    var candidates: [URL] = []
    if let plugInsURL = Bundle.main.builtInPlugInsURL {
      candidates.append(plugInsURL.appending(path: "Cemu.app"))
    }
    candidates.append(URL(fileURLWithPath: "/Applications/Cemu.app"))
    candidates.append(
      FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications", directoryHint: .isDirectory)
        .appending(path: "Cemu.app", directoryHint: .isDirectory)
    )
    return candidates.first(where: isUsableApplication(at:))
  }

  private static var defaultApplicationSupportURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "RetroVault", directoryHint: .isDirectory)
    .appending(path: "Cemu", directoryHint: .isDirectory)
  }

  private static var defaultProcessHomeURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  }

  private static var defaultCemuUserDataURL: URL {
    defaultProcessHomeURL
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Application Support", directoryHint: .isDirectory)
      .appending(path: "Cemu", directoryHint: .isDirectory)
  }

  private static func isUsableApplication(at url: URL) -> Bool {
    let executableURL = executableURL(in: url)
    guard
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: executableURL.path
      ),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let permissions = attributes[.posixPermissions] as? NSNumber
    else {
      return false
    }
    return permissions.intValue & 0o111 != 0
  }

  private static func executableURL(in applicationURL: URL) -> URL {
    let executableDirectory = applicationURL
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "MacOS", directoryHint: .isDirectory)
    let realExecutableURL = executableDirectory.appending(path: "Cemu.real")
    if FileManager.default.isExecutableFile(atPath: realExecutableURL.path) {
      return realExecutableURL
    }
    return executableDirectory.appending(path: "Cemu")
  }

  func prepareRuntime(
    dsuConfiguration: CemuDSUConfiguration?,
    contentURL: URL,
    mlcURL: URL
  ) throws -> CemuRuntime {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: applicationSupportURL,
      withIntermediateDirectories: true
    )

    let executableURL = Self.executableURL(in: sourceApplicationURL)
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
      throw CemuError.invalidInstallation
    }
    try fileManager.createDirectory(
      at: cemuUserDataURL,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: mlcURL,
      withIntermediateDirectories: true
    )
    if try Self.prepareRestoredSaveData(in: mlcURL) {
      RetroVaultLog.cemu.notice(
        "Mapped a restored RomM Cemu save bundle into the desktop MLC layout"
      )
    }
    try prepareSettings(
      in: cemuUserDataURL,
      gameDirectory: contentURL.deletingLastPathComponent(),
      mlcDirectory: mlcURL,
      dsuConfiguration: dsuConfiguration
    )
    if let dsuConfiguration {
      try prepareControllerProfile(
        dsuConfiguration,
        in: cemuUserDataURL
      )
    } else {
      removeManagedControllerProfile(in: cemuUserDataURL)
    }

    return CemuRuntime(
      applicationURL: sourceApplicationURL,
      executableURL: executableURL,
      userDataDirectory: cemuUserDataURL,
      homeDirectory: processHomeURL,
      logURL: cemuUserDataURL.appending(path: "log.txt")
    )
  }

  /// Converts Cannoli's portable per-title Cemu save bundle into the MLC
  /// layout expected by desktop Cemu.
  ///
  /// Cannoli stores the title directory at `save/` and records its Wii U title
  /// ID in `cannoli-standalone-save.txt`. Desktop Cemu instead reads that same
  /// directory from `usr/save/<high title ID>/<low title ID>/`. RomM may hold
  /// either representation, so normalize the portable form after download and
  /// before Cemu starts. The source is removed only after the replacement has
  /// succeeded, keeping interrupted migrations recoverable.
  @discardableResult
  static func prepareRestoredSaveData(in mlcURL: URL) throws -> Bool {
    let fileManager = FileManager.default
    guard let origin = try portableSaveOrigin(in: mlcURL) else {
      return false
    }

    let sourceURL = mlcURL.appending(
      path: "save",
      directoryHint: .isDirectory
    )
    var sourceIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: sourceURL.path,
        isDirectory: &sourceIsDirectory
      ),
      sourceIsDirectory.boolValue
    else {
      throw CemuError.invalidSaveBundle(
        "The RomM Cemu save bundle does not contain its save directory."
      )
    }

    let destinationURL = nativeSaveURL(
      in: mlcURL,
      titleID: origin.titleID
    )
    let destinationParentURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: destinationParentURL,
      withIntermediateDirectories: true
    )

    let stagingURL = destinationParentURL.appending(
      path: ".RetroVaultCemuSaveImport-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.copyItem(at: sourceURL, to: stagingURL)
    defer { try? fileManager.removeItem(at: stagingURL) }

    if fileManager.fileExists(atPath: destinationURL.path) {
      let backupName = ".RetroVaultCemuSaveBackup-\(UUID().uuidString)"
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: stagingURL,
        backupItemName: backupName,
        options: [.usingNewMetadataOnly]
      )
      try? fileManager.removeItem(
        at: destinationParentURL.appending(path: backupName)
      )
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }

    try fileManager.removeItem(at: sourceURL)
    try fileManager.removeItem(
      at: mlcURL.appending(path: "cannoli-standalone-save.txt")
    )
    return true
  }

  /// Identifies Cannoli's portable Cemu representation without changing it.
  static func portableSaveOrigin(
    in mlcURL: URL
  ) throws -> CemuPortableSaveOrigin? {
    let markerURL = mlcURL.appending(path: "cannoli-standalone-save.txt")
    guard FileManager.default.fileExists(atPath: markerURL.path) else {
      return nil
    }

    let markerData = try Data(contentsOf: markerURL)
    guard let marker = String(data: markerData, encoding: .utf8) else {
      throw CemuError.invalidSaveBundle(
        "The RomM Cemu save marker is not valid UTF-8."
      )
    }
    var fields: [String: String] = [:]
    for line in marker.split(whereSeparator: { $0.isNewline }) {
      let components = line.split(separator: "=", maxSplits: 1)
      guard components.count == 2 else { continue }
      fields[String(components[0])] = String(components[1])
    }
    let titleID = fields["title_id"]?
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
    guard
      fields["emulator"]?.uppercased() == "CEMU",
      let titleID,
      titleID.count == 16,
      titleID.allSatisfy(\.isHexDigit)
    else {
      throw CemuError.invalidSaveBundle(
        "The RomM Cemu save bundle has no valid Wii U title ID."
      )
    }
    return CemuPortableSaveOrigin(
      titleID: titleID,
      markerData: markerData
    )
  }

  /// Presents the current desktop Cemu save using the layout imported from
  /// RomM, then removes the temporary projection after `body` returns.
  ///
  /// Native MLC bundles are passed through unchanged. Cannoli bundles retain
  /// their exact marker bytes and expose only the per-title `save/` tree.
  static func withPreservedSaveBundle<T>(
    in mlcURL: URL,
    origin: CemuPortableSaveOrigin?,
    _ body: (URL) throws -> T
  ) throws -> T {
    guard let origin else {
      return try body(mlcURL)
    }

    let fileManager = FileManager.default
    let portableSourceURL = mlcURL.appending(
      path: "save",
      directoryHint: .isDirectory
    )
    let nativeSourceURL = nativeSaveURL(
      in: mlcURL,
      titleID: origin.titleID
    )
    let sourceURL = fileManager.fileExists(atPath: portableSourceURL.path)
      ? portableSourceURL
      : nativeSourceURL
    var sourceIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(
        atPath: sourceURL.path,
        isDirectory: &sourceIsDirectory
      ),
      sourceIsDirectory.boolValue
    else {
      throw CemuError.invalidSaveBundle(
        "Cemu's save data for Wii U title \(origin.titleID) is missing."
      )
    }

    let stagingURL = fileManager.temporaryDirectory.appending(
      path: "RetroVault-CemuSave-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: stagingURL) }

    try origin.markerData.write(
      to: stagingURL.appending(path: "cannoli-standalone-save.txt"),
      options: .atomic
    )
    try fileManager.copyItem(
      at: sourceURL,
      to: stagingURL.appending(path: "save", directoryHint: .isDirectory)
    )
    return try body(stagingURL)
  }

  private static func nativeSaveURL(
    in mlcURL: URL,
    titleID: String
  ) -> URL {
    mlcURL
      .appending(path: "usr/save", directoryHint: .isDirectory)
      .appending(
        path: String(titleID.prefix(8)),
        directoryHint: .isDirectory
      )
      .appending(
        path: String(titleID.suffix(8)),
        directoryHint: .isDirectory
      )
  }

  private func prepareSettings(
    in portableDirectory: URL,
    gameDirectory: URL,
    mlcDirectory: URL,
    dsuConfiguration: CemuDSUConfiguration?
  ) throws {
    let settingsURL = portableDirectory.appending(path: "settings.xml")
    // This is RetroVault's private Cemu user-data directory, so keep the small
    // configuration deterministic. An incomplete settings file makes Cemu
    // fall back to OpenGL, which is unsupported on Apple silicon under
    // Rosetta; Vulkan is required for the MoltenVK renderer.
    let dsuSettings = dsuConfiguration.map {
      """
          <Input>
            <DSUC host="\(xmlEscaped($0.host))" port="\($0.port)"/>
          </Input>
      """
    } ?? ""
    let settings = """
      <?xml version="1.0" encoding="UTF-8"?>
      <content>
        <macos_disclaimer>true</macos_disclaimer>
        <check_update>false</check_update>
        <receive_untested_updates>false</receive_untested_updates>
        <mlc_path>\(xmlEscaped(mlcDirectory.path))</mlc_path>
        <GamePaths>
          <Entry>\(xmlEscaped(gameDirectory.path))</Entry>
        </GamePaths>
        <fullscreen_menubar>false</fullscreen_menubar>
        <fullscreen>true</fullscreen>
        <disable_screensaver>true</disable_screensaver>
        <Graphic>
          <api>1</api>
        </Graphic>
        <Audio>
          <api>3</api>
          <delay>2</delay>
          <TVChannels>1</TVChannels>
          <PadChannels>1</PadChannels>
          <InputChannels>0</InputChannels>
          <TVVolume>50</TVVolume>
          <PadVolume>0</PadVolume>
          <InputVolume>50</InputVolume>
          <TVDevice>default</TVDevice>
          <PadDevice></PadDevice>
          <InputDevice></InputDevice>
        </Audio>
      \(dsuSettings)
      </content>
      """
    try settings.write(
      to: settingsURL,
      atomically: true,
      encoding: .utf8
    )
  }

  private func prepareControllerProfile(
    _ configuration: CemuDSUConfiguration,
    in portableDirectory: URL
  ) throws {
    let profilesDirectory = portableDirectory.appending(
      path: "controllerProfiles",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: profilesDirectory,
      withIntermediateDirectories: true
    )
    let profileURL = profilesDirectory.appending(path: "controller0.xml")
    let mappingEntries = CemuDSUMapping.proController.map {
      """
              <entry><mapping>\($0.emulated)</mapping><button>\($0.physical)</button></entry>
      """
    }
    .joined(separator: "\n")
    let profile = """
      <?xml version="1.0" encoding="UTF-8"?>
      <emulated_controller>
        <type>Wii U Pro Controller</type>
        <controller>
          <api>DSUController</api>
          <uuid>\(configuration.slot)</uuid>
          <display_name>RetroVault DSU Controller</display_name>
          <motion>false</motion>
          <axis><deadzone>0.15</deadzone><range>1</range></axis>
          <rotation><deadzone>0.15</deadzone><range>1</range></rotation>
          <trigger><deadzone>0.1</deadzone><range>1</range></trigger>
          <ip>\(xmlEscaped(configuration.host))</ip>
          <port>\(configuration.port)</port>
          <mappings>
      \(mappingEntries)
          </mappings>
        </controller>
      </emulated_controller>
      """
    try profile.write(
      to: profileURL,
      atomically: true,
      encoding: .utf8
    )
  }

  private func removeManagedControllerProfile(in portableDirectory: URL) {
    let profileURL = portableDirectory
      .appending(path: "controllerProfiles", directoryHint: .isDirectory)
      .appending(path: "controller0.xml")
    guard
      let contents = try? String(contentsOf: profileURL, encoding: .utf8),
      contents.contains("RetroVault DSU Controller")
    else {
      return
    }
    try? FileManager.default.removeItem(at: profileURL)
  }

  private func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

struct CemuRuntime: Hashable, Sendable {
  let applicationURL: URL
  let executableURL: URL
  let userDataDirectory: URL
  let homeDirectory: URL
  let logURL: URL

  /// Native Cemu quick-launch arguments. RetroVault executes the signed Cemu
  /// binary embedded in its own bundle directly so LaunchServices cannot
  /// rewrite the arguments or App-Translocate a copied application bundle.
  func launchArguments(contentURL: URL, mlcURL: URL) -> [String] {
    [
      "-g", contentURL.path,
      "-m", mlcURL.path,
      "-f",
    ]
  }

  func processEnvironment(
    merging environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = environment
    environment["HOME"] = homeDirectory.path
    return environment
  }
}

struct CemuDSUConfiguration: Hashable, Sendable {
  let host: String
  let port: UInt16
  let slot: Int
}

struct CemuRunRequest: Hashable, Sendable {
  let gameID: Int
  let title: String
  let contentURL: URL
  let saveSync: CartridgeSaveSyncConfiguration
}

enum CemuError: LocalizedError {
  case unavailable
  case invalidInstallation
  case invalidLaunchPath
  case invalidSaveBundle(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Cemu is not bundled in this RetroVault build."
    case .invalidInstallation:
      "RetroVault could not prepare its private Cemu installation."
    case .invalidLaunchPath:
      "The selected Wii U game or save path cannot be passed to Cemu."
    case .invalidSaveBundle(let reason):
      "RetroVault could not restore Cemu save data from RomM: \(reason)"
    case .launchFailed(let reason):
      "Cemu could not be launched: \(reason)"
    }
  }
}

private enum CemuDSUMapping {
  struct Entry {
    let emulated: Int
    let physical: Int
  }

  /// Wii U Pro Controller mappings for the semantic DSU layout emitted by
  /// Switch2Bridge. Cemu's Pro Controller mapping identifiers include an
  /// unused Home entry at 11, so the D-pad and stick identifiers start at 12.
  static let proController: [Entry] = [
    .init(emulated: 1, physical: 13), // A
    .init(emulated: 2, physical: 14), // B
    .init(emulated: 3, physical: 12), // X
    .init(emulated: 4, physical: 15), // Y
    .init(emulated: 5, physical: 10), // L
    .init(emulated: 6, physical: 11), // R
    .init(emulated: 7, physical: 42), // ZL
    .init(emulated: 8, physical: 43), // ZR
    .init(emulated: 9, physical: 3), // Plus
    .init(emulated: 10, physical: 0), // Minus
    .init(emulated: 12, physical: 4), // Up
    .init(emulated: 13, physical: 6), // Down
    .init(emulated: 14, physical: 7), // Left
    .init(emulated: 15, physical: 5), // Right
    .init(emulated: 16, physical: 1), // L3
    .init(emulated: 17, physical: 2), // R3
    .init(emulated: 18, physical: 39), // Left stick up
    .init(emulated: 19, physical: 45), // Left stick down
    .init(emulated: 20, physical: 44), // Left stick left
    .init(emulated: 21, physical: 38), // Left stick right
    .init(emulated: 22, physical: 41), // Right stick up
    .init(emulated: 23, physical: 47), // Right stick down
    .init(emulated: 24, physical: 46), // Right stick left
    .init(emulated: 25, physical: 40), // Right stick right
  ]
}
