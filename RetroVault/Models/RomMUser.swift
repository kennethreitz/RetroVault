import Foundation

/// The authenticated RomM user represented in RetroVault.
struct RomMUser: Equatable, Sendable {
    let id: Int
    let username: String
    let scopes: Set<String>
    /// RetroAchievements username and synced unlocks from this user's profile.
    /// Unlinked when RomM has no username stored.
    var retroAchievements: RetroAchievementsProfile = .unlinked
}
