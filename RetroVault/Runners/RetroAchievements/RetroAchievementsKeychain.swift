import Foundation
import Security

/// The signed-in RetroAchievements session token.
///
/// The password used to mint the token is never written here or to preferences.
struct RetroAchievementsSessionCredential: Equatable, Sendable {
  let username: String
  let token: String
}

enum RetroAchievementsTokenStore {
  private static let service = "org.kennethreitz.RetroVault.retroachievements"

  static func load() -> RetroAchievementsSessionCredential? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
      let record = item as? [String: Any],
      let username = record[kSecAttrAccount as String] as? String,
      let data = record[kSecValueData as String] as? Data,
      let token = String(data: data, encoding: .utf8),
      !username.isEmpty,
      !token.isEmpty
    else {
      return nil
    }
    return RetroAchievementsSessionCredential(username: username, token: token)
  }

  static func save(_ credential: RetroAchievementsSessionCredential) throws {
    delete()
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: credential.username,
      kSecValueData as String: Data(credential.token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw RetroAchievementsTokenStoreError.unreadable
    }
  }

  static func delete() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

enum RetroAchievementsTokenStoreError: LocalizedError {
  case unreadable

  var errorDescription: String? {
    "RetroVault could not store the RetroAchievements session in the Keychain."
  }
}
