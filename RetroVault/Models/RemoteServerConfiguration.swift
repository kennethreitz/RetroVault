import Foundation

/// The single remote RomM server configured for RetroVault.
struct RemoteServerConfiguration: Codable, Equatable, Sendable {
    let serverURL: ServerURL
    let username: String
}
