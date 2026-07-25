import Foundation

protocol RomMClient: Sendable {
    func verifyServer(at serverURL: ServerURL) async throws
    func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken
    func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser
    func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem]
    func collections(at serverURL: ServerURL, token: ClientToken) async throws -> [LibraryCollection]
    func games(
        at serverURL: ServerURL,
        token: ClientToken,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) async throws -> GamePage
}
