import Foundation

#if SWIFT_PACKAGE
import RCheevos
#endif

struct RetroAchievementsPlayNotice: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case loaded
    case unlock
    case mastery
    case subset
    case leaderboard
    case progress
    case reset
    case message
  }

  var kind: Kind
  var title: String
  var detail: String
  var badgeURL: URL?
  var points: Int
  var hardcore: Bool
}

/// One rcheevos client for a running game.
///
/// Calls that touch the client, other than queueing an HTTP response, stay on
/// the emulation thread. The password that created the stored token never
/// reaches this object.
final class RetroAchievementsPlaySession: @unchecked Sendable {
  private let lock = NSLock()
  private var client: OpaquePointer?
  private var isClosed = false
  private var didStartLoad = false
  private let contentPath: String
  private let consoleID: UInt32

  private init(client: OpaquePointer, contentPath: String, consoleID: UInt32) {
    self.client = client
    self.contentPath = contentPath
    self.consoleID = consoleID
  }

  /// Starts a session when a Keychain token and a known console are available.
  /// A missing sign-in returns nil so the game still launches.
  static func make(
    contentPath: String?,
    systemName: String?,
    coreID: String,
    hardcore: Bool
  ) -> RetroAchievementsPlaySession? {
    guard
      let contentPath,
      !contentPath.isEmpty,
      let consoleID = RetroAchievementsConsole.identifier(forSystemName: systemName),
      let credential = RetroAchievementsTokenStore.load(),
      let client = rvra_create()
    else {
      return nil
    }

    let session = RetroAchievementsPlaySession(
      client: client,
      contentPath: contentPath,
      consoleID: consoleID
    )
    let userdata = Unmanaged.passUnretained(session).toOpaque()
    rvra_set_http(client, retroAchievementsHTTP, userdata)
    rvra_set_memory(
      client,
      retroAchievementsMemoryData,
      retroAchievementsMemorySize,
      userdata
    )
    var clause = [CChar](repeating: 0, count: 80)
    rvra_rcheevos_clause(client, &clause, clause.count)
    let agent = RetroAchievementsUserAgent.gameplay(
      version: RetroAchievementsUserAgent.marketingVersion,
      coreID: coreID,
      rcheevosClause: String(cString: clause)
    )
    rvra_set_user_agent(client, agent)
    rvra_set_hardcore_enabled(client, hardcore ? 1 : 0)
    rvra_begin_login_with_token(client, credential.username, credential.token)
    return session
  }

  func setHardcore(_ enabled: Bool) {
    withClient { rvra_set_hardcore_enabled($0, enabled ? 1 : 0) }
  }

  func canPause() -> Bool {
    withClient { rvra_can_pause($0) != 0 } ?? true
  }

  func acknowledgeReset() {
    withClient { rvra_acknowledge_reset($0) }
  }

  func idle() {
    withClient { rvra_pump($0) }
  }

  func frame() {
    withClient { client in
      let state = rvra_login_state(client)
      if state == RVRA_LOGIN_SUCCEEDED, !didStartLoad {
        didStartLoad = true
        rvra_begin_load_game(client, consoleID, contentPath)
      }
      rvra_frame(client)
    }
  }

  func poll() -> [RetroAchievementsPlayNotice] {
    guard let client = lockedClient() else {
      return []
    }
    var notices: [RetroAchievementsPlayNotice] = []
    while true {
      var kind = Int32(0)
      var points = Int32(0)
      var hardcore = Int32(0)
      var title = [CChar](repeating: 0, count: 192)
      var detail = [CChar](repeating: 0, count: 384)
      var badge = [CChar](repeating: 0, count: 384)
      let found = rvra_poll_notice(
        client,
        &kind,
        &title,
        title.count,
        &detail,
        detail.count,
        &badge,
        badge.count,
        &points,
        &hardcore
      )
      if found == 0 {
        break
      }
      notices.append(
        RetroAchievementsPlayNotice(
          kind: kind,
          title: String(cString: title),
          detail: String(cString: detail),
          badge: String(cString: badge),
          points: Int(points),
          hardcore: hardcore != 0
        )
      )
    }
    return notices
  }

  func gameState() -> Int32 {
    withClient { rvra_game_state($0) } ?? RVRA_GAME_IDLE
  }

  func summary() -> (unlocked: Int, total: Int) {
    var unlocked = Int32(0)
    var total = Int32(0)
    var unlockedPoints = Int32(0)
    var possiblePoints = Int32(0)
    withClient {
      rvra_game_summary($0, &unlocked, &total, &unlockedPoints, &possiblePoints)
    }
    return (Int(unlocked), Int(total))
  }

  func loginResult() -> Int32 {
    withClient { rvra_login_state($0) } ?? RVRA_LOGIN_IDLE
  }

  func loginError() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    withClient { rvra_login_error($0, &buffer, buffer.count) }
    return String(cString: buffer)
  }

  func richPresence() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    withClient { rvra_rich_presence($0, &buffer, buffer.count) }
    return String(cString: buffer)
  }

  func leaderboardTracker() -> String {
    var buffer = [CChar](repeating: 0, count: 96)
    withClient { rvra_leaderboard_tracker($0, &buffer, buffer.count) }
    return String(cString: buffer)
  }

  func close() {
    lock.lock()
    isClosed = true
    let client = self.client
    self.client = nil
    lock.unlock()
    if let client {
      rvra_destroy(client)
    }
  }

  fileprivate func memoryData(id: UInt32) -> UnsafeMutableRawPointer? {
    achievementMemoryProvider?(id).data
  }

  fileprivate func memorySize(id: UInt32) -> Int {
    achievementMemoryProvider?(id).size ?? 0
  }

  var achievementMemoryProvider: ((UInt32) -> (data: UnsafeMutableRawPointer?, size: Int))?

  fileprivate func performHTTP(
    id: UInt64,
    url: String,
    post: String?,
    contentType: String?
  ) {
    guard let target = URL(string: url), target.scheme?.lowercased() == "https" else {
      completeHTTP(id: id, status: -1, body: nil)
      return
    }
    var request = URLRequest(url: target)
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    if let post {
      request.httpMethod = "POST"
      request.httpBody = Data(post.utf8)
      if let contentType, !contentType.isEmpty {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      }
    }
    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      self?.completeHTTP(id: id, status: status, body: data)
    }.resume()
  }

  private func userAgent() -> String {
    var buffer = [CChar](repeating: 0, count: 160)
    withClient { rvra_user_agent($0, &buffer, buffer.count) }
    let value = String(cString: buffer)
    return value.isEmpty ? RetroAchievementsUserAgent.currentProduct : value
  }

  private func completeHTTP(id: UInt64, status: Int, body: Data?) {
    lock.lock()
    defer { lock.unlock() }
    guard let client, !isClosed else {
      return
    }
    if let body, !body.isEmpty {
      body.withUnsafeBytes { bytes in
        rvra_complete_http(client, id, Int32(status), bytes.baseAddress, body.count)
      }
    } else {
      rvra_complete_http(client, id, Int32(status), nil, 0)
    }
  }

  private func lockedClient() -> OpaquePointer? {
    lock.lock()
    defer { lock.unlock() }
    return isClosed ? nil : client
  }

  private func withClient<T>(_ body: (OpaquePointer) -> T) -> T? {
    guard let client = lockedClient() else {
      return nil
    }
    return body(client)
  }
}

private func retroAchievementsHTTP(
  _ userdata: UnsafeMutableRawPointer?,
  _ requestID: UInt64,
  _ url: UnsafePointer<CChar>?,
  _ post: UnsafePointer<CChar>?,
  _ contentType: UnsafePointer<CChar>?
) {
  guard let userdata, let url else {
    return
  }
  let session = Unmanaged<RetroAchievementsPlaySession>.fromOpaque(userdata)
    .takeUnretainedValue()
  session.performHTTP(
    id: requestID,
    url: String(cString: url),
    post: post.map { String(cString: $0) },
    contentType: contentType.map { String(cString: $0) }
  )
}

private func retroAchievementsMemoryData(
  _ memoryID: UInt32,
  _ userdata: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
  guard let userdata else {
    return nil
  }
  return Unmanaged<RetroAchievementsPlaySession>.fromOpaque(userdata)
    .takeUnretainedValue()
    .memoryData(id: memoryID)
}

private func retroAchievementsMemorySize(
  _ memoryID: UInt32,
  _ userdata: UnsafeMutableRawPointer?
) -> Int {
  guard let userdata else {
    return 0
  }
  return Unmanaged<RetroAchievementsPlaySession>.fromOpaque(userdata)
    .takeUnretainedValue()
    .memorySize(id: memoryID)
}

extension RetroAchievementsPlayNotice {
  fileprivate init(
    kind rawKind: Int32,
    title: String,
    detail: String,
    badge: String,
    points: Int,
    hardcore: Bool
  ) {
    switch rawKind {
    case RVRA_NOTICE_UNLOCK:
      kind = .unlock
    case RVRA_NOTICE_MASTERY:
      kind = .mastery
    case RVRA_NOTICE_SUBSET:
      kind = .subset
    case RVRA_NOTICE_LEADERBOARD:
      kind = .leaderboard
    case RVRA_NOTICE_PROGRESS:
      kind = .progress
    case RVRA_NOTICE_RESET:
      kind = .reset
    default:
      kind = .message
    }
    self.title = title
    self.detail = detail
    badgeURL = badge.isEmpty ? nil : URL(string: badge)
    self.points = points
    self.hardcore = hardcore
  }
}
