import Foundation

/// RetroAchievements data that RomM already stores for the signed-in user.
///
/// RomM keeps a server API key, each user's RetroAchievements username, the
/// matched game id, the achievement set, and that user's synced unlocks. It
/// does not store a RetroAchievements password or login token. RetroVault
/// therefore only displays this data. Unlocking during play is separate:
/// RetroVault runs the emulator, hardcore mode needs RetroAchievements to
/// verify that emulator, and a player login would have to live in the Keychain.
struct RetroAchievementsProfile: Equatable, Sendable {
  /// RetroAchievements username saved on the RomM user. Nil when none is set.
  let username: String?
  /// Unlock summaries keyed by the RetroAchievements game id (`rom_ra_id`).
  let gamesByRetroAchievementsID: [Int: RetroAchievementsGameProgress]

  static let unlinked = RetroAchievementsProfile(
    username: nil,
    gamesByRetroAchievementsID: [:]
  )

  var isLinked: Bool {
    username != nil
  }

  func progress(for retroAchievementsID: Int) -> RetroAchievementsGameProgress? {
    gamesByRetroAchievementsID[retroAchievementsID]
  }
}

/// One game's unlock summary from RomM's stored RetroAchievements progression.
struct RetroAchievementsGameProgress: Equatable, Sendable {
  /// Achievements RetroAchievements counts as earned, including softcore.
  let earnedCount: Int
  /// Achievements earned in hardcore mode.
  let earnedHardcoreCount: Int
  /// Maximum points the set can award. This is not an achievement count.
  let maximumPoints: Int?
  /// RetroAchievements award such as `mastered` or `beaten-softcore`.
  let highestAwardKind: String?
  /// Timestamp string RomM stored for the latest unlock.
  let mostRecentAwardedAt: String?
  let unlocks: [RetroAchievementsUnlock]
}

/// One earned achievement inside a RomM progression record.
struct RetroAchievementsUnlock: Equatable, Sendable {
  /// Badge name. RomM 5.4 stores this in `id`, and several achievements can share it.
  let badgeName: String
  /// Achievement id when the server sends `ra_id`. Absent on RomM 5.4.1.
  let achievementID: Int?
  let earnedAt: String
  let hardcoreEarnedAt: String?
}

/// Whether RetroVault could read the signed-in user's RetroAchievements profile.
enum RetroAchievementsProfileState: Equatable, Sendable {
  /// A request is still in flight.
  case unknown
  /// This view is not contacting RomM, so unlocks are not available.
  case notRequested
  /// RomM did not return a profile. This is distinct from an unlinked username.
  case failed
  case loaded(RetroAchievementsProfile)
}

/// The achievement set RomM stored for one matched ROM.
struct RetroAchievementsCatalog: Codable, Hashable, Sendable {
  /// RetroAchievements game id (`ra_id`).
  let gameID: Int
  /// True when RomM confirmed the ROM hash is in RetroAchievements' list.
  /// Nil when that server did not send `hash_match`.
  let hashMatched: Bool?
  let achievements: [RetroAchievement]

  var pageURL: URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "retroachievements.org"
    components.path = "/game/\(gameID)"
    return components.url
  }

  var possiblePoints: Int {
    achievements.reduce(0) { $0 + $1.points }
  }
}

/// One achievement in a RomM RetroAchievements set.
struct RetroAchievement: Codable, Hashable, Sendable, Identifiable {
  /// RetroAchievements achievement id. Synthetic negative ids fill gaps when
  /// a server omits `ra_id` on a row.
  let id: Int
  let title: String
  let summary: String
  let points: Int
  /// Badge file name. Several achievements in one set can share it.
  let badgeName: String?
  let lockedBadgeURL: URL?
  let unlockedBadgeURL: URL?
  let displayOrder: Int
  /// RetroAchievements category such as `progression` or `missable`.
  let kind: String?
}

/// How a matched achievement set is shown for the current RomM user.
struct RetroAchievementsPresentation: Equatable, Sendable {
  struct Row: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let summary: String
    let points: Int
    let badgeURL: URL?
    let isEarned: Bool
    let isHardcore: Bool
    let earnedAt: Date?
    let earnedAtText: String?
    let kindTitle: String?
  }

  let gameID: Int
  let username: String?
  let rows: [Row]
  /// Nil when personal unlocks are hidden.
  let earnedCount: Int?
  let hardcoreEarnedCount: Int?
  let possibleCount: Int
  /// Nil when personal unlocks are hidden.
  let earnedPoints: Int?
  let possiblePoints: Int
  let awardTitle: String?
  let hashMatched: Bool?
  let pageURL: URL
  let profileState: RetroAchievementsProfileState

  var showsPersonalProgress: Bool {
    if case .loaded(let profile) = profileState, profile.isLinked {
      return true
    }
    return false
  }

  /// Short library label such as `12/75`. Nil when progress should stay hidden.
  var progressLabel: String? {
    guard showsPersonalProgress, let earnedCount else {
      return nil
    }
    return "\(earnedCount.formatted())/\(possibleCount.formatted())"
  }

  /// Count shown when the set exists but unlocks are hidden.
  var setSizeLabel: String {
    possibleCount.formatted()
  }

  var statusMessage: String? {
    switch profileState {
    case .unknown:
      return "Checking RetroAchievements progress…"
    case .notRequested:
      return "Connect to RomM to see unlock progress."
    case .failed:
      return "RomM didn’t return RetroAchievements progress. The set is still shown."
    case .loaded(let profile):
      guard let username = profile.username else {
        return "This RomM user has no RetroAchievements username, so unlocks stay hidden."
      }
      return "Unlocks from RomM’s last sync for \(username)."
    }
  }

  /// Builds the visible set. Returns nil when the ROM has no achievement set,
  /// which is how unmatched ROMs stay hidden.
  static func make(
    catalog: RetroAchievementsCatalog?,
    profileState: RetroAchievementsProfileState
  ) -> RetroAchievementsPresentation? {
    guard
      let catalog,
      !catalog.achievements.isEmpty,
      let pageURL = catalog.pageURL
    else {
      return nil
    }

    let progress: RetroAchievementsGameProgress?
    let showsPersonalProgress: Bool
    if case .loaded(let profile) = profileState, profile.isLinked {
      showsPersonalProgress = true
      progress = profile.progress(for: catalog.gameID)
    } else {
      showsPersonalProgress = false
      progress = nil
    }

    let unlocks = progress?.unlocks ?? []
    let rows = catalog.achievements
      .sorted { lhs, rhs in
        if lhs.displayOrder == rhs.displayOrder {
          return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return lhs.displayOrder < rhs.displayOrder
      }
      .map { achievement in
        let unlock = showsPersonalProgress
          ? matchingUnlock(for: achievement, in: unlocks)
          : nil
        let earnedAtText = unlock?.hardcoreEarnedAt ?? unlock?.earnedAt
        return Row(
          id: achievement.id,
          title: achievement.title,
          summary: achievement.summary,
          points: achievement.points,
          badgeURL: {
            // A locked badge means "you have not earned this". Hide that
            // implication until RomM has actually supplied this user's unlocks.
            guard showsPersonalProgress else {
              return achievement.unlockedBadgeURL ?? achievement.lockedBadgeURL
            }
            guard unlock != nil else {
              return achievement.lockedBadgeURL ?? achievement.unlockedBadgeURL
            }
            return achievement.unlockedBadgeURL ?? achievement.lockedBadgeURL
          }(),
          isEarned: unlock != nil,
          isHardcore: unlock?.hardcoreEarnedAt != nil,
          earnedAt: earnedAtText.flatMap(RetroAchievementsDate.date(from:)),
          earnedAtText: earnedAtText,
          kindTitle: kindTitle(achievement.kind)
        )
      }

    let earnedRows = rows.filter(\.isEarned)
    return RetroAchievementsPresentation(
      gameID: catalog.gameID,
      username: {
        if case .loaded(let profile) = profileState {
          return profile.username
        }
        return nil
      }(),
      rows: rows,
      earnedCount: showsPersonalProgress ? earnedRows.count : nil,
      hardcoreEarnedCount: showsPersonalProgress
        ? rows.filter(\.isHardcore).count
        : nil,
      possibleCount: rows.count,
      earnedPoints: showsPersonalProgress
        ? earnedRows.reduce(0) { $0 + $1.points }
        : nil,
      possiblePoints: catalog.possiblePoints,
      awardTitle: showsPersonalProgress
        ? awardTitle(progress?.highestAwardKind)
        : nil,
      hashMatched: catalog.hashMatched,
      pageURL: pageURL,
      profileState: profileState
    )
  }

  /// Matches an unlock to an achievement.
  ///
  /// Newer RomM servers store the achievement id on each unlock. RomM 5.4.1
  /// only stores the badge name, which more than one achievement can share,
  /// so a legacy unlock can mark every achievement that uses that badge.
  static func matchingUnlock(
    for achievement: RetroAchievement,
    in unlocks: [RetroAchievementsUnlock]
  ) -> RetroAchievementsUnlock? {
    if achievement.id > 0,
      let identified = unlocks.first(where: { $0.achievementID == achievement.id })
    {
      return identified
    }

    guard let badgeName = achievement.badgeName, !badgeName.isEmpty else {
      return nil
    }
    return unlocks.first {
      $0.achievementID == nil && $0.badgeName == badgeName
    }
  }

  static func awardTitle(_ kind: String?) -> String? {
    switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "":
      return nil
    case "mastered":
      return "Mastered"
    case "completed":
      return "Completed"
    case "beaten-hardcore":
      return "Beaten (Hardcore)"
    case "beaten-softcore":
      return "Beaten"
    case let other?:
      return other
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
    }
  }

  static func kindTitle(_ kind: String?) -> String? {
    switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "":
      return nil
    case "progression":
      return "Progression"
    case "win_condition":
      return "Win Condition"
    case "missable":
      return "Missable"
    case let other?:
      return other
        .replacingOccurrences(of: "_", with: " ")
        .capitalized
    }
  }
}

enum RetroAchievementsDate {
  /// Parses the timestamp strings RomM copies from RetroAchievements.
  static func date(from value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: trimmed) {
      return date
    }
    let internet = ISO8601DateFormatter()
    if let date = internet.date(from: trimmed) {
      return date
    }

    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: trimmed) {
        return date
      }
    }
    return nil
  }
}
