import Foundation
import ZIPFoundation

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
    mlcURL: URL,
    launchPresentation: CemuLaunchPresentation,
    internalResolution: LibretroInternalResolution = .native
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
      dsuConfiguration: dsuConfiguration,
      launchPresentation: launchPresentation,
      internalResolution: internalResolution
    )
    if let dsuConfiguration {
      removeManagedControllerProfiles(in: cemuUserDataURL)
      try prepareControllerProfiles(
        dsuConfiguration,
        in: cemuUserDataURL
      )
    } else {
      removeManagedControllerProfiles(in: cemuUserDataURL)
    }

    return CemuRuntime(
      applicationURL: sourceApplicationURL,
      executableURL: executableURL,
      userDataDirectory: cemuUserDataURL,
      homeDirectory: processHomeURL,
      logURL: cemuUserDataURL.appending(path: "log.txt")
    )
  }

  /// Installs Cemu's official community graphics packs when a higher internal
  /// resolution was requested. The archive is kept in RetroVault's private
  /// Cemu data directory and reused by later launches.
  @discardableResult
  func ensureGraphicPacksAvailable(
    for resolution: LibretroInternalResolution
  ) async throws -> Bool {
    guard resolution != .native else {
      return false
    }
    return try await CemuGraphicPackInstaller.ensureInstalled(
      in: cemuUserDataURL
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
    dsuConfiguration: CemuDSUConfiguration?,
    launchPresentation: CemuLaunchPresentation,
    internalResolution: LibretroInternalResolution
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
    let graphicPackSettings = try CemuGraphicPackCatalog.settingsXML(
      in: portableDirectory,
      resolution: internalResolution,
      xmlEscaped: xmlEscaped
    )
    if internalResolution != .native {
      if graphicPackSettings == "  <GraphicPack/>" {
        RetroVaultLog.cemu.notice(
          "No compatible Cemu \(internalResolution.displayName, privacy: .public) graphics-pack preset was found; using the title's native resolution"
        )
      } else {
        RetroVaultLog.cemu.notice(
          "Configured Cemu graphics packs for \(internalResolution.displayName, privacy: .public) internal resolution"
        )
      }
    }
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
      \(graphicPackSettings)
        <fullscreen_menubar>false</fullscreen_menubar>
        <fullscreen>\(launchPresentation.settingsValue)</fullscreen>
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

  private func prepareControllerProfiles(
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
    let mappingEntries = CemuDSUMapping.proController.map {
      """
              <entry><mapping>\($0.emulated)</mapping><button>\($0.physical)</button></entry>
      """
    }
    .joined(separator: "\n")
    for playerIndex in 0..<configuration.playerCount {
      let profileURL = profilesDirectory.appending(
        path: "controller\(playerIndex).xml"
      )
      let profile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <emulated_controller>
          <type>Wii U Pro Controller</type>
          <controller>
            <api>DSUController</api>
            <uuid>\(playerIndex)</uuid>
            <display_name>RetroVault DSU Controller \(playerIndex + 1)</display_name>
            <motion>false</motion>
            <rumble>1</rumble>
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
  }

  private func removeManagedControllerProfiles(in portableDirectory: URL) {
    let profilesDirectory = portableDirectory.appending(
      path: "controllerProfiles",
      directoryHint: .isDirectory
    )
    for playerIndex in 0..<Int(DSUProtocol.slotCount) {
      let profileURL = profilesDirectory.appending(
        path: "controller\(playerIndex).xml"
      )
      guard
        let contents = try? String(contentsOf: profileURL, encoding: .utf8),
        contents.contains("RetroVault DSU Controller")
      else {
        continue
      }
      try? FileManager.default.removeItem(at: profileURL)
    }
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

enum CemuGraphicPackCatalog {
  private struct Preset {
    let name: String
    let category: String?
    let values: [String: String]
  }

  private struct Rules {
    let definition: [String: String]
    let defaults: [String: String]
    let presets: [Preset]
  }

  private struct Selection {
    let rulesURL: URL
    let category: String?
    let preset: String
    let error: Double
  }

  static func settingsXML(
    in userDataDirectory: URL,
    resolution: LibretroInternalResolution,
    xmlEscaped: (String) -> String
  ) throws -> String {
    guard resolution != .native else {
      return "  <GraphicPack/>"
    }

    let graphicPacksURL = userDataDirectory.appending(
      path: "graphicPacks",
      directoryHint: .isDirectory
    )
    guard
      let enumerator = FileManager.default.enumerator(
        at: graphicPacksURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return "  <GraphicPack/>"
    }

    var selections: [Selection] = []
    for case let rulesURL as URL in enumerator where rulesURL.lastPathComponent == "rules.txt" {
      guard
        let contents = try? String(contentsOf: rulesURL, encoding: .utf8),
        let selection = selection(
          in: parse(contents),
          rulesURL: rulesURL,
          scale: resolution.scale
        )
      else {
        continue
      }
      selections.append(selection)
    }

    selections.sort {
      $0.rulesURL.path.localizedStandardCompare($1.rulesURL.path)
        == .orderedAscending
    }
    guard !selections.isEmpty else {
      return "  <GraphicPack/>"
    }

    let rootPath = userDataDirectory.standardizedFileURL.path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let entries = selections.compactMap { selection -> String? in
      let path = selection.rulesURL.standardizedFileURL.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard path.hasPrefix(rootPath + "/") else {
        return nil
      }
      let relativePath = String(path.dropFirst(rootPath.count + 1))
      let categoryAttribute = selection.category.map {
        " category=\"\(xmlEscaped($0))\""
      } ?? ""
      return """
          <Entry filename="\(xmlEscaped(relativePath))">
            <Preset\(categoryAttribute) preset="\(xmlEscaped(selection.preset))"/>
          </Entry>
      """
    }
    guard !entries.isEmpty else {
      return "  <GraphicPack/>"
    }
    return """
        <GraphicPack>
    \(entries.joined(separator: "\n"))
        </GraphicPack>
    """
  }

  private static func selection(
    in rules: Rules,
    rulesURL: URL,
    scale: Int
  ) -> Selection? {
    let definitionDescription = [
      rules.definition["name"],
      rules.definition["path"],
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    .lowercased()

    return rules.presets.compactMap { preset -> Selection? in
      let normalizedCategory = preset.category?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let categoryDescription = normalizedCategory?.lowercased() ?? ""
      let isResolutionPreset: Bool
      if categoryDescription.isEmpty {
        isResolutionPreset = definitionDescription.contains("resolution")
      } else {
        isResolutionPreset = categoryDescription.contains("resolution")
          && !categoryDescription.contains("gamepad")
          && !categoryDescription.contains("game pad")
      }
      guard isResolutionPreset else {
        return nil
      }

      let effectiveValues = rules.defaults.merging(preset.values) { _, preset in
        preset
      }
      guard
        let width = integerValue(effectiveValues["$width"]),
        let height = integerValue(effectiveValues["$height"]),
        let gameWidth = integerValue(effectiveValues["$gamewidth"]),
        let gameHeight = integerValue(effectiveValues["$gameheight"]),
        gameWidth > 0,
        gameHeight > 0
      else {
        return nil
      }
      let widthScale = Double(width) / Double(gameWidth)
      let heightScale = Double(height) / Double(gameHeight)
      let target = Double(scale)
      let error = abs(widthScale - target) + abs(heightScale - target)
      guard error <= 0.1 else {
        return nil
      }
      let selectedCategory = normalizedCategory.flatMap {
        $0.isEmpty ? nil : $0
      }
      return Selection(
        rulesURL: rulesURL,
        category: selectedCategory,
        preset: preset.name,
        error: error
      )
    }
    .min {
      if $0.error != $1.error {
        return $0.error < $1.error
      }
      return $0.preset.localizedStandardCompare($1.preset) == .orderedAscending
    }
  }

  private static func parse(_ contents: String) -> Rules {
    enum Section {
      case definition
      case defaults
      case preset
      case ignored
    }

    var section = Section.ignored
    var definition: [String: String] = [:]
    var defaults: [String: String] = [:]
    var currentPreset: [String: String] = [:]
    var presets: [Preset] = []

    func normalizedKey(_ value: String) -> String {
      value
        .split(separator: ":", maxSplits: 1)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    }

    func appendPreset() {
      guard let name = currentPreset["name"], !name.isEmpty else {
        currentPreset = [:]
        return
      }
      let category = currentPreset["category"]
      presets.append(
        Preset(name: name, category: category, values: currentPreset)
      )
      currentPreset = [:]
    }

    for rawLine in contents.split(
      omittingEmptySubsequences: false,
      whereSeparator: { $0.isNewline }
    ) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
        continue
      }
      if line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") {
        if section == .preset {
          appendPreset()
        }
        let name = line[line.index(after: line.startIndex)..<closingBracket]
          .lowercased()
        switch name {
        case "definition": section = .definition
        case "default": section = .defaults
        case "preset": section = .preset
        default: section = .ignored
        }
        continue
      }
      guard
        let separator = line.firstIndex(of: "="),
        separator != line.startIndex
      else {
        continue
      }
      let key = normalizedKey(String(line[..<separator]))
      var value = String(line[line.index(after: separator)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value.count >= 2, value.first == "\"", value.last == "\"" {
        value.removeFirst()
        value.removeLast()
      }
      switch section {
      case .definition: definition[key] = value
      case .defaults: defaults[key] = value
      case .preset: currentPreset[key] = value
      case .ignored: break
      }
    }
    if section == .preset {
      appendPreset()
    }
    return Rules(
      definition: definition,
      defaults: defaults,
      presets: presets
    )
  }

  private static func integerValue(_ value: String?) -> Int? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = trimmed.prefix { $0.isNumber }
    return prefix.isEmpty ? nil : Int(prefix)
  }
}

private enum CemuGraphicPackInstaller {
  private static let releasesURL = URL(
    string: "https://api.github.com/repos/cemu-project/cemu_graphic_packs/releases/latest"
  )!
  private static let maximumEntryCount = 50_000
  private static let maximumArchiveBytes = 64 * 1_024 * 1_024
  private static let maximumUncompressedBytes: UInt64 = 1_024 * 1_024 * 1_024

  private struct Release: Decodable {
    let assets: [Asset]
  }

  private struct Asset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  static func ensureInstalled(in userDataDirectory: URL) async throws -> Bool {
    let fileManager = FileManager.default
    let graphicPacksURL = userDataDirectory.appending(
      path: "graphicPacks",
      directoryHint: .isDirectory
    )
    let destinationURL = graphicPacksURL.appending(
      path: "downloadedGraphicPacks",
      directoryHint: .isDirectory
    )
    let markerURL = destinationURL.appending(path: "version.txt")
    if fileManager.fileExists(atPath: markerURL.path),
      containsRules(in: destinationURL)
    {
      return false
    }

    var request = URLRequest(url: releasesURL)
    request.setValue("RetroVault", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (releaseData, releaseResponse) = try await URLSession.shared.data(for: request)
    try validate(releaseResponse, data: releaseData)
    let release = try JSONDecoder().decode(Release.self, from: releaseData)
    guard let asset = release.assets.first(where: {
      $0.name.lowercased().hasSuffix(".zip")
    }) else {
      throw CemuGraphicPackError.releaseHasNoArchive
    }

    let (archiveData, archiveResponse) = try await URLSession.shared.data(from: asset.browserDownloadURL)
    try validate(archiveResponse, data: archiveData)
    guard archiveData.count <= maximumArchiveBytes else {
      throw CemuGraphicPackError.archiveTooLarge
    }

    try fileManager.createDirectory(
      at: graphicPacksURL,
      withIntermediateDirectories: true
    )
    let archiveURL = fileManager.temporaryDirectory.appending(
      path: "RetroVault-CemuGraphicPacks-\(UUID().uuidString).zip"
    )
    let stagingURL = graphicPacksURL.appending(
      path: ".RetroVaultCemuGraphicPacks-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try archiveData.write(to: archiveURL, options: .atomic)
    try fileManager.createDirectory(
      at: stagingURL,
      withIntermediateDirectories: true
    )
    defer {
      try? fileManager.removeItem(at: archiveURL)
      try? fileManager.removeItem(at: stagingURL)
    }

    let archive = try Archive(url: archiveURL, accessMode: .read)
    let entries = Array(archive)
    guard !entries.isEmpty, entries.count <= maximumEntryCount else {
      throw CemuGraphicPackError.archiveTooLarge
    }
    var uncompressedBytes: UInt64 = 0
    for entry in entries {
      guard entry.type != .symlink, isSafePath(entry.path) else {
        throw CemuGraphicPackError.unsafeEntry(entry.path)
      }
      let (total, overflow) = uncompressedBytes.addingReportingOverflow(
        entry.uncompressedSize
      )
      guard !overflow, total <= maximumUncompressedBytes else {
        throw CemuGraphicPackError.archiveTooLarge
      }
      uncompressedBytes = total
    }
    for entry in entries {
      let destination = stagingURL.appending(path: entry.path)
      if entry.type == .directory {
        try fileManager.createDirectory(
          at: destination,
          withIntermediateDirectories: true
        )
      } else {
        _ = try archive.extract(entry, to: destination)
      }
    }
    guard containsRules(in: stagingURL) else {
      throw CemuGraphicPackError.archiveHasNoRules
    }
    try asset.name.write(
      to: stagingURL.appending(path: "version.txt"),
      atomically: true,
      encoding: .utf8
    )

    if fileManager.fileExists(atPath: destinationURL.path) {
      let backupName = ".RetroVaultCemuGraphicPacksBackup-\(UUID().uuidString)"
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: stagingURL,
        backupItemName: backupName,
        options: [.usingNewMetadataOnly]
      )
      try? fileManager.removeItem(at: graphicPacksURL.appending(path: backupName))
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
    return true
  }

  private static func validate(_ response: URLResponse, data: Data) throws {
    guard
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw CemuGraphicPackError.downloadFailed
    }
    guard !data.isEmpty else {
      throw CemuGraphicPackError.downloadFailed
    }
  }

  private static func containsRules(in directory: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return false
    }
    return enumerator.contains { value in
      (value as? URL)?.lastPathComponent == "rules.txt"
    }
  }

  private static func isSafePath(_ path: String) -> Bool {
    guard
      !path.isEmpty,
      !path.hasPrefix("/"),
      !path.contains("\\")
    else {
      return false
    }
    let normalized = path.hasSuffix("/")
      ? String(path.dropLast())
      : path
    guard !normalized.isEmpty else { return false }
    let components = normalized.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }
}

private enum CemuGraphicPackError: LocalizedError {
  case downloadFailed
  case releaseHasNoArchive
  case archiveTooLarge
  case archiveHasNoRules
  case unsafeEntry(String)

  var errorDescription: String? {
    switch self {
    case .downloadFailed:
      "Cemu's official graphics packs could not be downloaded."
    case .releaseHasNoArchive:
      "Cemu's latest graphics-pack release has no ZIP archive."
    case .archiveTooLarge:
      "Cemu's graphics-pack archive is unexpectedly large."
    case .archiveHasNoRules:
      "Cemu's graphics-pack archive contains no usable rules."
    case .unsafeEntry(let path):
      "Cemu's graphics-pack archive contains an unsafe entry: \(path)"
    }
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
  func launchArguments(
    contentURL: URL,
    mlcURL: URL,
    presentation: CemuLaunchPresentation
  ) -> [String] {
    var arguments = [
      "-g", contentURL.path,
      "-m", mlcURL.path,
    ]
    if presentation == .fullScreen {
      arguments.append("-f")
    }
    return arguments
  }

  func processEnvironment(
    merging environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = environment
    environment["HOME"] = homeDirectory.path
    return environment
  }
}

enum CemuLaunchPresentation: Hashable, Sendable {
  case windowed
  case fullScreen

  static func matching(hostWindowIsFullScreen: Bool) -> Self {
    hostWindowIsFullScreen ? .fullScreen : .windowed
  }

  var settingsValue: String {
    self == .fullScreen ? "true" : "false"
  }

  var logDescription: String {
    self == .fullScreen ? "fullscreen" : "windowed"
  }
}

struct CemuDSUConfiguration: Hashable, Sendable {
  let host: String
  let port: UInt16
  let playerCount: Int

  init(
    host: String,
    port: UInt16,
    playerCount: Int = 1
  ) {
    self.host = host
    self.port = port
    self.playerCount = min(
      max(playerCount, 1),
      Int(DSUProtocol.slotCount)
    )
  }
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
