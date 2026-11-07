import Foundation
import Observation

#if SWIFT_PACKAGE
import RCheevos
#endif

/// Signs a RetroAchievements player in and keeps only the resulting token.
///
/// The password exists for the length of the login request. It is not written
/// to the Keychain or to preferences.
@MainActor
@Observable
final class RetroAchievementsAccount {
  static let shared = RetroAchievementsAccount()

  private(set) var signedInUsername: String?
  private(set) var isWorking = false
  var statusMessage: String?
  var usernameDraft = ""

  private let queue = DispatchQueue(label: "org.kennethreitz.RetroVault.retroachievements.login")

  private init() {
    signedInUsername = RetroAchievementsTokenStore.load()?.username
  }

  func refresh() {
    signedInUsername = RetroAchievementsTokenStore.load()?.username
  }

  func prefillUsername(_ username: String?) {
    guard usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let username,
      !username.isEmpty
    else {
      return
    }
    usernameDraft = username
  }

  func signIn(password: String) async {
    let username = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty, !password.isEmpty else {
      statusMessage = "Enter the RetroAchievements username and password."
      return
    }
    guard !isWorking else {
      return
    }
    isWorking = true
    statusMessage = nil
    defer { isWorking = false }

    do {
      let credential = try await login(username: username, password: password)
      try RetroAchievementsTokenStore.save(credential)
      signedInUsername = credential.username
      usernameDraft = credential.username
      statusMessage = "Signed in. Achievements unlock the next time a game starts."
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  func signOut() {
    RetroAchievementsTokenStore.delete()
    signedInUsername = nil
    statusMessage = "Signed out of RetroAchievements."
  }

  private func login(
    username: String,
    password: String
  ) async throws -> RetroAchievementsSessionCredential {
    try await withCheckedThrowingContinuation { continuation in
      let attempt = RetroAchievementsLoginAttempt(
        username: username,
        queue: queue,
        continuation: continuation
      )
      queue.async {
        attempt.start(password: password)
      }
    }
  }
}

private final class RetroAchievementsLoginAttempt: @unchecked Sendable {
  let username: String
  let queue: DispatchQueue
  private var continuation: CheckedContinuation<RetroAchievementsSessionCredential, Error>?
  private var client: OpaquePointer?
  private var resumed = false
  private var lifetime: RetroAchievementsLoginAttempt?
  private let lock = NSLock()

  init(
    username: String,
    queue: DispatchQueue,
    continuation: CheckedContinuation<RetroAchievementsSessionCredential, Error>
  ) {
    self.username = username
    self.queue = queue
    self.continuation = continuation
  }

  func start(password: String) {
    lifetime = self
    guard let client = rvra_create() else {
      finish(.failure(RetroAchievementsLoginError.unavailable))
      return
    }
    self.client = client
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    rvra_set_http(client, retroAchievementsLoginHTTP, userdata)
    rvra_set_product_version(client, RetroAchievementsUserAgent.marketingVersion)
    rvra_set_hardcore_enabled(client, 0)
    rvra_begin_login_with_password(client, username, password)
    // The password argument ends with this call. rcheevos copies what it
    // needs into the login request, and this object does not keep it.
    rvra_pump(client)
    settleIfFinished()
    queue.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.finish(.failure(RetroAchievementsLoginError.timedOut))
    }
  }

  func performHTTP(id: UInt64, url: String, post: String?, contentType: String?) {
    guard let target = URL(string: url), target.scheme?.lowercased() == "https" else {
      queue.async { [weak self] in
        self?.complete(id: id, status: -1, body: nil)
      }
      return
    }
    var request = URLRequest(url: target)
    var agent = [CChar](repeating: 0, count: 160)
    if let client {
      rvra_user_agent(client, &agent, agent.count)
    }
    let header = String(cString: agent)
    request.setValue(
      header.isEmpty ? RetroAchievementsUserAgent.currentProduct : header,
      forHTTPHeaderField: "User-Agent"
    )
    if let post {
      request.httpMethod = "POST"
      request.httpBody = Data(post.utf8)
      if let contentType, !contentType.isEmpty {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      }
    }
    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      self?.queue.async {
        self?.complete(id: id, status: status, body: data)
      }
    }.resume()
  }

  private func complete(id: UInt64, status: Int, body: Data?) {
    guard let client, !resumed else {
      return
    }
    if let body, !body.isEmpty {
      body.withUnsafeBytes { bytes in
        rvra_complete_http(client, id, Int32(status), bytes.baseAddress, body.count)
      }
    } else {
      rvra_complete_http(client, id, Int32(status), nil, 0)
    }
    rvra_pump(client)
    settleIfFinished()
  }

  private func settleIfFinished() {
    guard let client else {
      return
    }
    switch rvra_login_state(client) {
    case RVRA_LOGIN_SUCCEEDED:
      var token = [CChar](repeating: 0, count: 128)
      var name = [CChar](repeating: 0, count: 64)
      rvra_session_token(client, &token, token.count)
      rvra_session_username(client, &name, name.count)
      let credential = RetroAchievementsSessionCredential(
        username: String(cString: name),
        token: String(cString: token)
      )
      guard !credential.username.isEmpty, !credential.token.isEmpty else {
        finish(.failure(RetroAchievementsLoginError.rejected("RetroAchievements did not return a session.")))
        return
      }
      finish(.success(credential))
    case RVRA_LOGIN_FAILED:
      var message = [CChar](repeating: 0, count: 256)
      rvra_login_error(client, &message, message.count)
      let text = String(cString: message)
      finish(.failure(RetroAchievementsLoginError.rejected(
        text.isEmpty ? "RetroAchievements did not accept the sign-in." : text
      )))
    default:
      break
    }
  }

  private func finish(_ result: Result<RetroAchievementsSessionCredential, Error>) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let alreadyResumed = resumed
    resumed = true
    let client = self.client
    self.client = nil
    lock.unlock()
    guard !alreadyResumed, let continuation else {
      return
    }
    if let client {
      rvra_destroy(client)
    }
    continuation.resume(with: result)
    lifetime = nil
  }
}

private func retroAchievementsLoginHTTP(
  _ userdata: UnsafeMutableRawPointer?,
  _ requestID: UInt64,
  _ url: UnsafePointer<CChar>?,
  _ post: UnsafePointer<CChar>?,
  _ contentType: UnsafePointer<CChar>?
) {
  guard let userdata, let url else {
    return
  }
  let attempt = Unmanaged<RetroAchievementsLoginAttempt>.fromOpaque(userdata)
    .takeUnretainedValue()
  attempt.performHTTP(
    id: requestID,
    url: String(cString: url),
    post: post.map { String(cString: $0) },
    contentType: contentType.map { String(cString: $0) }
  )
}

enum RetroAchievementsLoginError: LocalizedError {
  case unavailable
  case timedOut
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "RetroAchievements is unavailable."
    case .timedOut:
      "RetroAchievements did not answer. Try signing in again."
    case let .rejected(message):
      message
    }
  }
}
