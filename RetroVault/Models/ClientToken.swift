import Foundation

/// A secret RomM client token.
///
/// The raw value must remain in the credential store and must never be logged.
struct ClientToken: Equatable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        let prefix = "rmm_"
        let secret = rawValue.dropFirst(prefix.count)
        let isHexadecimal = secret.allSatisfy(\.isHexDigit)

        guard rawValue.hasPrefix(prefix), secret.count == 64, isHexadecimal else {
            throw ClientTokenError.invalid
        }

        self.rawValue = rawValue
    }
}

enum ClientTokenError: LocalizedError, Equatable {
    case invalid

    var errorDescription: String? {
        "RomM returned an invalid client token."
    }
}
