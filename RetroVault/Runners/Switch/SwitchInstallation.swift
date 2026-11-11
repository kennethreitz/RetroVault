import Foundation
import ZIPFoundation

/// Locates the optional Ryubing (Ryujinx fork) engine and owns its private
/// Switch data root.
///
/// Ryubing is hosted, not linked. RetroVault passes it a private `-r` root so
/// the user's own Ryujinx profile, saves, and firmware are never touched.
struct SwitchInstallation: Sendable {
  static let systemName = "Nintendo Switch"
  static let supportedFileExtensions = ["nsp", "xci", "nca", "nro", "nso"]
  static let productKeysFileName = "prod.keys"
  static let titleKeysFileName = "title.keys"

  let executableURL: URL
  let dataRootURL: URL

  static var available: SwitchInstallation? {
    guard let executableURL = detectedExecutableURL else {
      return nil
    }
    return SwitchInstallation(
      executableURL: executableURL,
      dataRootURL: defaultDataRootURL
    )
  }

  /// True only for the first Switch. Switch 2 has no maintained macOS engine;
  /// keeping it out here prevents the library from offering a launch that
  /// cannot work.
  static func supports(systemName: String) -> Bool {
    guard available != nil else {
      return false
    }
    return isSwitchSystemName(systemName)
  }

  /// Pure name mapping, separated from engine availability so it can be
  /// tested without Ryujinx installed.
  static func isSwitchSystemName(_ systemName: String) -> Bool {
    let normalized = systemName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized == "switch"
      || normalized == "switch 1"
      || normalized == "nintendo switch"
      || normalized == "nintendo switch 1"
  }

  static var setupStatus: SwitchSetupStatus {
    SwitchSetupStatus(
      engineInstalled: detectedExecutableURL != nil,
      hasProductKeys: containsKeys(at: defaultDataRootURL),
      hasTitleKeys: FileManager.default.fileExists(
        atPath: defaultDataRootURL
          .appending(path: "system")
          .appending(path: titleKeysFileName)
          .path
      ),
      hasFirmware: containsFirmware(at: defaultDataRootURL)
    )
  }

  static var defaultDataRootURL: URL {
    FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "RetroVault", directoryHint: .isDirectory)
    .appending(path: "Switch", directoryHint: .isDirectory)
    .appending(path: "Ryujinx", directoryHint: .isDirectory)
  }

  var systemDirectoryURL: URL {
    dataRootURL.appending(path: "system", directoryHint: .isDirectory)
  }

  var productKeysURL: URL {
    systemDirectoryURL.appending(path: Self.productKeysFileName)
  }

  var titleKeysURL: URL {
    systemDirectoryURL.appending(path: Self.titleKeysFileName)
  }

  var firmwareDirectoryURL: URL {
    dataRootURL
      .appending(path: "bis", directoryHint: .isDirectory)
      .appending(path: "system", directoryHint: .isDirectory)
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "registered", directoryHint: .isDirectory)
  }

  func saveDirectoryURL(for titleID: String) -> URL {
    dataRootURL
      .appending(path: "bis", directoryHint: .isDirectory)
      .appending(path: "user", directoryHint: .isDirectory)
      .appending(path: "save", directoryHint: .isDirectory)
      .appending(path: titleID, directoryHint: .isDirectory)
  }

  func recordDiagnostic(_ message: String) {
    Self.recordDiagnostic(message, at: dataRootURL)
  }

  static func recordDiagnostic(
    _ message: String,
    at dataRootURL: URL = defaultDataRootURL
  ) {
    let url = dataRootURL.appending(path: "retrovault-switch.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)
    do {
      try FileManager.default.createDirectory(
        at: dataRootURL,
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: url.path),
        let handle = try? FileHandle(forWritingTo: url)
      {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: url, options: .atomic)
      }
    } catch {
      // Diagnostics must never fail a launch.
    }
  }

  /// Validates the engine and the owner-supplied system files before a large
  /// game download starts.
  func validateReady() throws {
    guard Self.isExecutable(executableURL) else {
      throw SwitchError.unavailable
    }
    guard Self.containsKeys(at: dataRootURL) else {
      throw SwitchError.missingProductKeys
    }
    // Firmware is not a hard prerequisite: Ryujinx boots many titles without
    // it. Import it from the console when a game reports missing services.
  }

  /// Prepares the private root and links Ryujinx's save folder for `titleID`
  /// to RetroVault's managed save bundle, so the existing RomM save sync
  /// uploads and restores a normal directory bundle.
  func prepareRuntime(
    saveSync: CartridgeSaveSyncConfiguration,
    titleID: String
  ) throws -> SwitchRuntime {
    try validateReady()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: dataRootURL,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: systemDirectoryURL,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: saveSync.localSaveURL,
      withIntermediateDirectories: true
    )
    try migrateLegacyManagedSave(at: saveSync.localSaveURL)
    try linkSaveDirectory(
      at: saveDirectoryURL(for: titleID),
      to: saveSync.localSaveURL.appending(
        path: "title",
        directoryHint: .isDirectory
      )
    )
    try linkMatchingDeviceSaves(
      titleID: titleID,
      managedRoot: saveSync.localSaveURL
    )

    return SwitchRuntime(
      executableURL: executableURL,
      dataRootURL: dataRootURL,
      logURL: dataRootURL.appending(path: "Logs", directoryHint: .isDirectory)
    )
  }

  /// Adopts device-save data written during the session, then links it into the
  /// managed bundle. Call this after Ryujinx exits and before save sync.
  func adoptDeviceSaves(
    titleID: String,
    saveSync: CartridgeSaveSyncConfiguration
  ) throws {
    try linkSaveDirectory(
      at: saveDirectoryURL(for: titleID),
      to: saveSync.localSaveURL.appending(
        path: "title",
        directoryHint: .isDirectory
      )
    )
    try linkMatchingDeviceSaves(
      titleID: titleID,
      managedRoot: saveSync.localSaveURL
    )
  }

  func installProductKeys(from url: URL) throws {
    try installKeys(from: url, as: Self.productKeysFileName)
  }

  func installTitleKeys(from url: URL) throws {
    try installKeys(from: url, as: Self.titleKeysFileName)
  }

  /// Imports a dumped `registered` folder, its parent, or a ZIP that contains
  /// one. Nothing is installed until at least one `.nca` file is found.
  func installFirmware(from url: URL) throws {
    let fileManager = FileManager.default
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }

    var temporaryDirectory: URL?
    defer {
      if let temporaryDirectory {
        try? fileManager.removeItem(at: temporaryDirectory)
      }
    }

    let source: URL
    if url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
      let staging = FileManager.default.temporaryDirectory.appending(
        path: "RetroVault-SwitchFirmware-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try fileManager.createDirectory(
        at: staging,
        withIntermediateDirectories: true
      )
      temporaryDirectory = staging
      do {
        try fileManager.unzipItem(at: url, to: staging)
      } catch {
        throw SwitchError.firmwareImportFailed(error.localizedDescription)
      }
      source = staging
    } else {
      source = url
    }

    guard let registered = Self.registeredDirectory(in: source) else {
      throw SwitchError.firmwareImportFailed(
        "Choose the console's registered folder, its parent, or a ZIP containing one."
      )
    }

    let files = (try? fileManager.contentsOfDirectory(
      at: registered,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let ncAs = files.filter {
      $0.pathExtension.caseInsensitiveCompare("nca") == .orderedSame
    }
    guard !ncAs.isEmpty else {
      throw SwitchError.firmwareImportFailed(
        "The selected folder has no Switch firmware .nca files."
      )
    }

    try fileManager.createDirectory(
      at: firmwareDirectoryURL,
      withIntermediateDirectories: true
    )
    for file in files {
      guard
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
          == true
      else {
        continue
      }
      let destination = firmwareDirectoryURL.appending(
        path: file.lastPathComponent
      )
      if fileManager.fileExists(atPath: destination.path) {
        try? fileManager.removeItem(at: destination)
      }
      try fileManager.copyItem(at: file, to: destination)
    }
  }

  static func titleID(
    saveTarget: String?,
    titleID: String?,
    fileName: String
  ) -> String? {
    if let normalized = normalizedTitleID(saveTarget) {
      return normalized
    }
    if let normalized = normalizedTitleID(titleID) {
      return normalized
    }

    guard
      let range = fileName.range(
        of: #"\[[0-9A-Fa-f]{16}\]"#,
        options: .regularExpression
      )
    else {
      return nil
    }
    return fileName[range]
      .dropFirst()
      .dropLast()
      .lowercased()
  }

  private static func normalizedTitleID(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "0x", with: "")
      .lowercased()
    guard normalized.count == 16,
      normalized.allSatisfy(\.isHexDigit)
    else {
      return nil
    }
    return normalized
  }

  private static func containsKeys(at dataRootURL: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: dataRootURL
        .appending(path: "system")
        .appending(path: productKeysFileName)
        .path
    )
  }

  private static func containsFirmware(at dataRootURL: URL) -> Bool {
    containsNCA(
      in: dataRootURL.appending(
        path: "bis/system/Contents/registered",
        directoryHint: .isDirectory
      )
    )
  }

  private static func registeredDirectory(in source: URL) -> URL? {
    let fileManager = FileManager.default
    let candidates = [
      source.appending(path: "Contents/registered", directoryHint: .isDirectory),
      source.appending(path: "registered", directoryHint: .isDirectory),
      source,
    ]
    for candidate in candidates where containsNCA(in: candidate) {
      return candidate
    }

    // A ZIP often wraps the dump in an extra folder. Search deeper for a
    // `registered` directory rather than asking the user to flatten it.
    guard
      let enumerator = fileManager.enumerator(
        at: source,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return nil
    }
    while let candidate = enumerator.nextObject() as? URL {
      guard
        (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
          == true
      else {
        continue
      }
      if candidate.lastPathComponent.caseInsensitiveCompare("registered")
        == .orderedSame,
        containsNCA(in: candidate)
      {
        return candidate
      }
    }
    return nil
  }

  private static func containsNCA(in directory: URL) -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
    return files.contains {
      $0.pathExtension.caseInsensitiveCompare("nca") == .orderedSame
    }
  }

  private static var detectedExecutableURL: URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var candidates: [URL] = []

    if let plugInsURL = Bundle.main.builtInPlugInsURL {
      candidates.append(
        appExecutable(
          at: plugInsURL.appending(path: "Ryujinx.app")
        )
      )
    }
    for application in [
      URL(fileURLWithPath: "/Applications/Ryujinx.app"),
      home.appending(path: "Applications", directoryHint: .isDirectory)
        .appending(path: "Ryujinx.app", directoryHint: .isDirectory),
    ] {
      candidates.append(appExecutable(at: application))
    }

    // A nixpkgs `ryubing` install is a `Ryujinx` executable, not an .app.
    // Check the standard profile locations before falling back to PATH.
    candidates.append(
      URL(fileURLWithPath: "/run/current-system/sw/bin/Ryujinx")
    )
    candidates.append(
      URL(
        fileURLWithPath:
          "/etc/profiles/per-user/\(NSUserName())/bin/Ryujinx"
      )
    )
    candidates.append(
      home.appending(path: ".nix-profile/bin/Ryujinx")
    )
    candidates.append(
      URL(fileURLWithPath: "/nix/var/nix/profiles/default/bin/Ryujinx")
    )
    candidates.append(
      home.appending(path: ".local/bin/Ryujinx")
    )
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      for directory in path.split(separator: ":") where !directory.isEmpty {
        candidates.append(
          URL(fileURLWithPath: String(directory))
            .appending(path: "Ryujinx")
        )
      }
    }

    return candidates.first(where: isExecutable)
  }

  private static func appExecutable(at applicationURL: URL) -> URL {
    applicationURL
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "MacOS", directoryHint: .isDirectory)
      .appending(path: "Ryujinx")
  }

  private static func isExecutable(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: url.path,
        isDirectory: &isDirectory
      ),
      !isDirectory.boolValue
    else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: url.path)
  }

  private func installKeys(from url: URL, as fileName: String) throws {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw SwitchError.invalidKeyFile(error.localizedDescription)
    }
    guard
      !data.isEmpty,
      let text = String(data: data.prefix(4_096), encoding: .utf8),
      text.contains("=")
    else {
      throw SwitchError.invalidKeyFile(
        "That file does not look like a Switch key file."
      )
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: systemDirectoryURL,
      withIntermediateDirectories: true
    )
    let destination = systemDirectoryURL.appending(path: fileName)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try data.write(to: destination, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
  }

  private func linkMatchingDeviceSaves(
    titleID: String,
    managedRoot: URL
  ) throws {
    let saveRoot = dataRootURL
      .appending(path: "bis", directoryHint: .isDirectory)
      .appending(path: "user", directoryHint: .isDirectory)
      .appending(path: "save", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    let candidates = (try? fileManager.contentsOfDirectory(
      at: saveRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    for candidate in candidates where candidate.lastPathComponent != titleID {
      guard
        (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
          == true,
        Self.directoryOwnedBy(titleID: titleID, at: candidate)
      else {
        continue
      }
      let destination = managedRoot
        .appending(path: "device", directoryHint: .isDirectory)
        .appending(
          path: candidate.lastPathComponent,
          directoryHint: .isDirectory
        )
      try linkSaveDirectory(at: candidate, to: destination)
    }
  }

  /// Moves pre-device-save bundles from the old flat layout into `title/`.
  private func migrateLegacyManagedSave(at managedRoot: URL) throws {
    let fileManager = FileManager.default
    let titleRoot = managedRoot.appending(
      path: "title",
      directoryHint: .isDirectory
    )
    let children = (try? fileManager.contentsOfDirectory(
      at: managedRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
    let legacy = children.filter {
      !["title", "device"].contains($0.lastPathComponent)
    }
    guard !legacy.isEmpty else {
      return
    }
    try fileManager.createDirectory(
      at: titleRoot,
      withIntermediateDirectories: true
    )
    for child in legacy {
      let destination = titleRoot.appending(path: child.lastPathComponent)
      if !fileManager.fileExists(atPath: destination.path) {
        try fileManager.moveItem(at: child, to: destination)
      }
    }
  }

  /// Device-save directories store their owning title ID little-endian at the
  /// start of ExtraData0/1. This lets a shared device-save area be projected
  /// only into the game that owns it.
  private static func directoryOwnedBy(
    titleID: String,
    at directory: URL
  ) -> Bool {
    guard let expected = UInt64(titleID, radix: 16) else {
      return false
    }
    for fileName in ["ExtraData0", "ExtraData1"] {
      let fileURL = directory.appending(path: fileName)
      guard
        let data = try? Data(contentsOf: fileURL),
        data.count >= 8
      else {
        continue
      }
      var value: UInt64 = 0
      for (index, byte) in data.prefix(8).enumerated() {
        value |= UInt64(byte) << (8 * index)
      }
      if value == expected {
        return true
      }
    }
    return false
  }

  private func linkSaveDirectory(at saveDirectory: URL, to managedURL: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: managedURL,
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: saveDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if let existingTarget = try? fileManager.destinationOfSymbolicLink(
      atPath: saveDirectory.path
    ) {
      if URL(fileURLWithPath: existingTarget).standardizedFileURL
        == managedURL.standardizedFileURL
      {
        return
      }
      try fileManager.removeItem(at: saveDirectory)
    } else if fileManager.fileExists(atPath: saveDirectory.path) {
      // Adopt saves Ryujinx wrote before the managed bundle was linked. The
      // managed bundle wins on conflicts, so a restored RomM save is not lost.
      let children = (try? fileManager.contentsOfDirectory(
        at: saveDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
      for child in children {
        let destination = managedURL.appending(path: child.lastPathComponent)
        if !fileManager.fileExists(atPath: destination.path) {
          try fileManager.moveItem(at: child, to: destination)
        }
      }
      try fileManager.removeItem(at: saveDirectory)
    }

    try fileManager.createSymbolicLink(
      at: saveDirectory,
      withDestinationURL: managedURL
    )
  }
}

struct SwitchSetupStatus: Sendable {
  let engineInstalled: Bool
  let hasProductKeys: Bool
  let hasTitleKeys: Bool
  let hasFirmware: Bool
}

struct SwitchRuntime: Hashable, Sendable {
  let executableURL: URL
  let dataRootURL: URL
  let logURL: URL

  /// Ryubing quick-launch arguments. `-r` keeps Ryujinx's configuration,
  /// firmware, and saves inside RetroVault's private root. `-g vulkan` selects
  /// the bundled MoltenVK backend on Apple silicon.
  func launchArguments(
    contentURL: URL,
    presentation: SwitchLaunchPresentation
  ) -> [String] {
    var arguments = [
      "-r", dataRootURL.path,
      "-g", "vulkan",
      "--docked-mode",
    ]
    if presentation == .fullScreen {
      arguments.append("-f")
    }
    arguments.append(contentURL.path)
    return arguments
  }

  func processEnvironment(
    merging environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    environment
  }
}

enum SwitchLaunchPresentation: Hashable, Sendable {
  case windowed
  case fullScreen

  static func matching(hostWindowIsFullScreen: Bool) -> Self {
    hostWindowIsFullScreen ? .fullScreen : .windowed
  }
}

struct SwitchRunRequest: Codable, Hashable, Sendable {
  let gameID: Int
  let title: String
  let contentURL: URL
  let saveSync: CartridgeSaveSyncConfiguration
  let titleID: String
}

enum SwitchError: LocalizedError {
  case unavailable
  case missingProductKeys
  case invalidTitleID
  case invalidKeyFile(String)
  case firmwareImportFailed(String)
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      """
      RetroVault could not find its Ryubing companion. Rebuild with \
      Scripts/fetch-ryujinx-companion.sh, or use an unsandboxed build with \
      Ryujinx.app installed, then try again.
      """
    case .missingProductKeys:
      """
      Switch games need prod.keys from your own console. Choose it in \
      Settings → Nintendo Switch.
      """
    case .invalidTitleID:
      """
      RomM has not recorded this game's Switch title ID. Rescan the file in \
      RomM, then try again.
      """
    case .invalidKeyFile(let reason):
      "RetroVault could not read that key file: \(reason)"
    case .firmwareImportFailed(let reason):
      "RetroVault could not import that firmware: \(reason)"
    case .launchFailed(let reason):
      "Ryubing could not be launched: \(reason)"
    }
  }
}
