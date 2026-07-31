import Foundation

/// The authenticated RomM user represented in RetroVault.
struct RomMUser: Equatable, Sendable {
    let id: Int
    let username: String
    let scopes: Set<String>
}
