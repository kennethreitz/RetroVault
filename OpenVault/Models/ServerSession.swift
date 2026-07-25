import Foundation

/// Non-secret state for the server currently used by OpenVault.
struct ServerSession: Equatable, Sendable {
    let serverURL: ServerURL
    let username: String
}
