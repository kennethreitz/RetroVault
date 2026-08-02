@preconcurrency import AppKit
import Darwin
import Foundation

/// Locates and prepares the Cemu companion application used for Wii U games.
///
/// Cemu is a standalone emulator rather than a Libretro core. RetroVault keeps
/// a private portable copy so Cemu's configuration, shader cache, and logs do
/// not leak into or depend on a user's separate Cemu installation.
struct CemuInstallation: Sendable {
  static let systemName = "Wii U"
  static let supportedFileExtensions = ["wua", "wux", "wud", "rpx"]
  private static let runtimeRevision = "launcher-1"

  let sourceApplicationURL: URL
  let applicationSupportURL: URL

  static var available: CemuInstallation? {
    guard let sourceApplicationURL else {
      return nil
    }
    return CemuInstallation(
      sourceApplicationURL: sourceApplicationURL,
      applicationSupportURL: defaultApplicationSupportURL
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
    applicationURL
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "MacOS", directoryHint: .isDirectory)
      .appending(path: "Cemu")
  }

  func prepareRuntime(
    dsuConfiguration: CemuDSUConfiguration?
  ) throws -> CemuRuntime {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: applicationSupportURL,
      withIntermediateDirectories: true
    )

    let runtimeDirectory = applicationSupportURL.appending(
      path: "Runtime",
      directoryHint: .isDirectory
    )
    let runtimeApplicationURL = runtimeDirectory.appending(
      path: "Cemu.app",
      directoryHint: .isDirectory
    )
    let sourceVersion = "\(applicationVersion(at: sourceApplicationURL))-\(Self.runtimeRevision)"
    let versionMarkerURL = runtimeDirectory.appending(path: "source-version.txt")
    let installedVersion = try? String(
      contentsOf: versionMarkerURL,
      encoding: .utf8
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)

    if !Self.isUsableApplication(at: runtimeApplicationURL)
      || installedVersion != sourceVersion
    {
      let stagingDirectory = applicationSupportURL.appending(
        path: "Staging-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? fileManager.removeItem(at: stagingDirectory) }
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )
      let stagedApplicationURL = stagingDirectory.appending(
        path: "Cemu.app",
        directoryHint: .isDirectory
      )
      try fileManager.copyItem(
        at: sourceApplicationURL,
        to: stagedApplicationURL
      )
      Self.removeQuarantineRecursively(at: stagedApplicationURL)
      if fileManager.fileExists(atPath: runtimeDirectory.path) {
        try fileManager.removeItem(at: runtimeDirectory)
      }
      try fileManager.moveItem(
        at: stagingDirectory,
        to: runtimeDirectory
      )
      try sourceVersion.write(
        to: versionMarkerURL,
        atomically: true,
        encoding: .utf8
      )
    }

    // FileManager adds a quarantine marker when a sandboxed app copies an
    // executable bundle. The source companion is already part of RetroVault's
    // signed bundle, so remove that inherited marker from our private copy.
    // Do this on every launch to repair runtimes created by older builds.
    Self.removeQuarantineRecursively(at: runtimeApplicationURL)

    guard Self.isUsableApplication(at: runtimeApplicationURL) else {
      throw CemuError.invalidInstallation
    }

    let portableDirectory = runtimeDirectory.appending(
      path: "portable",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: portableDirectory,
      withIntermediateDirectories: true
    )
    try prepareSettings(in: portableDirectory)
    if let dsuConfiguration {
      try prepareControllerProfile(
        dsuConfiguration,
        in: portableDirectory
      )
    } else {
      removeManagedControllerProfile(in: portableDirectory)
    }

    return CemuRuntime(
      applicationURL: runtimeApplicationURL,
      executableURL: Self.executableURL(in: runtimeApplicationURL),
      portableDirectory: portableDirectory,
      logURL: portableDirectory.appending(path: "log.txt")
    )
  }

  private func applicationVersion(at url: URL) -> String {
    let bundle = Bundle(url: url)
    return bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
  }

  private static func removeQuarantineRecursively(at rootURL: URL) {
    var urlsToRepair = [rootURL]
    if let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: nil
    ) {
      for case let childURL as URL in enumerator {
        urlsToRepair.append(childURL)
      }
    }

    for urlToRepair in urlsToRepair {
      urlToRepair.withUnsafeFileSystemRepresentation { path in
        guard let path else { return }
        _ = removexattr(path, "com.apple.quarantine", 0)
      }
    }
  }

  private func prepareSettings(in portableDirectory: URL) throws {
    let settingsURL = portableDirectory.appending(path: "settings.xml")
    // This is RetroVault's private Cemu runtime, so keep the small launcher
    // configuration deterministic. An incomplete settings file makes Cemu
    // fall back to OpenGL, which is unsupported on Apple silicon under
    // Rosetta; Vulkan is required for the MoltenVK renderer.
    let settings = """
      <?xml version="1.0" encoding="UTF-8"?>
      <content>
        <macos_disclaimer>true</macos_disclaimer>
        <check_update>false</check_update>
        <receive_untested_updates>false</receive_untested_updates>
        <fullscreen_menubar>false</fullscreen_menubar>
        <fullscreen>true</fullscreen>
        <disable_screensaver>true</disable_screensaver>
        <Graphic>
          <api>1</api>
        </Graphic>
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
    let mappingEntries = CemuDSUMapping.gamePad.map {
      """
              <entry><mapping>\($0.emulated)</mapping><button>\($0.physical)</button></entry>
      """
    }
    .joined(separator: "\n")
    let profile = """
      <?xml version="1.0" encoding="UTF-8"?>
      <emulated_controller>
        <type>Wii U GamePad</type>
        <toggle_display>0</toggle_display>
        <controller>
          <api>DSUController</api>
          <uuid>\(configuration.slot)</uuid>
          <display_name>RetroVault DSU Controller</display_name>
          <motion>true</motion>
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
  let portableDirectory: URL
  let logURL: URL

  var launchRequestURL: URL {
    portableDirectory.appending(path: "retrovault-launch.txt")
  }

  /// Atomically records the title and private MLC paths consumed by the
  /// bundled Cemu launcher on its next invocation.
  func writeLaunchRequest(contentURL: URL, mlcURL: URL) throws {
    let paths = [contentURL.path, mlcURL.path]
    guard paths.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
      throw CemuError.invalidLaunchPath
    }
    try (paths.joined(separator: "\n") + "\n").write(
      to: launchRequestURL,
      atomically: true,
      encoding: .utf8
    )
  }

  func removeLaunchRequest() {
    try? FileManager.default.removeItem(at: launchRequestURL)
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
  case launchFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Cemu is not bundled in this RetroVault build."
    case .invalidInstallation:
      "RetroVault could not prepare its private Cemu installation."
    case .invalidLaunchPath:
      "The selected Wii U game or save path cannot be passed to Cemu."
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

  /// Wii U GamePad mappings for the semantic DSU layout emitted by
  /// Switch2Bridge and consumed elsewhere in RetroVault.
  static let gamePad: [Entry] = [
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
    .init(emulated: 11, physical: 4), // Up
    .init(emulated: 12, physical: 6), // Down
    .init(emulated: 13, physical: 7), // Left
    .init(emulated: 14, physical: 5), // Right
    .init(emulated: 15, physical: 1), // L3
    .init(emulated: 16, physical: 2), // R3
    .init(emulated: 17, physical: 39), // Left stick up
    .init(emulated: 18, physical: 45), // Left stick down
    .init(emulated: 19, physical: 44), // Left stick left
    .init(emulated: 20, physical: 38), // Left stick right
    .init(emulated: 21, physical: 41), // Right stick up
    .init(emulated: 22, physical: 47), // Right stick down
    .init(emulated: 23, physical: 46), // Right stick left
    .init(emulated: 24, physical: 40), // Right stick right
  ]
}
