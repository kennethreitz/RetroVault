import Foundation

/// The player-facing Hardcore switch.
///
/// RetroVault is not a RetroAchievements-verified emulator, so this stays off
/// until someone turns it on. The token for a signed-in player is not stored
/// here.
enum RetroAchievementsHardcore {
  static let enabledKey = "retroachievements.hardcore.enabled"

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }
}

/// What Hardcore mode is allowed to do while it is on.
///
/// RetroAchievements rejects hardcore credit from an emulator that loads save
/// states, rewinds, changes speed, or applies cheats. RetroVault has no cheat
/// device; the cheat rule stays false so a later one cannot bypass this.
enum RetroAchievementsHardcorePolicy {
  static func allowsSaveStateLoading(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsSaveStateWriting(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsRewind(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsFastForward(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsSlowMotion(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsCheats(hardcoreEnabled: Bool) -> Bool {
    !hardcoreEnabled
  }

  static func allowsSpeedChange(hardcoreEnabled: Bool) -> Bool {
    allowsFastForward(hardcoreEnabled: hardcoreEnabled)
      && allowsSlowMotion(hardcoreEnabled: hardcoreEnabled)
  }
}

/// The product half of the RetroAchievements user agent.
///
/// The rcheevos clause is appended by the client. The name is RetroVault's
/// own, with the app's numeric version, and it does not pretend to be
/// another emulator.
enum RetroAchievementsUserAgent {
  static func product(version: String) -> String {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = trimmed.isEmpty ? "0" : trimmed
    return "RetroVault/\(resolved)"
  }

  static var marketingVersion: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? ""
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "0" : trimmed
  }

  static var currentProduct: String {
    product(version: marketingVersion)
  }

  static func gameplay(
    version: String,
    coreID: String,
    rcheevosClause: String
  ) -> String {
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let platform = "macOS \(system.majorVersion).\(system.minorVersion)"
    let core = coreID.trimmingCharacters(in: .whitespacesAndNewlines)
    let clause = rcheevosClause.trimmingCharacters(in: .whitespacesAndNewlines)
    return [product(version: version), "(\(platform))", core, clause]
      .filter { !$0.isEmpty && $0 != "()" }
      .joined(separator: " ")
  }
}
