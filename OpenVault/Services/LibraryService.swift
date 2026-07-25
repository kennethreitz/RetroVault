import Foundation

protocol LibraryServing: Sendable {
    func systems(in session: ServerSession) async throws -> [LibrarySystem]
    func collections(in session: ServerSession) async throws -> [LibraryCollection]
    func games(
        in session: ServerSession,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) async throws -> GamePage
    func artworkRequest(for game: GameSummary, in session: ServerSession) async throws -> URLRequest?
}

actor RomMLibraryService: LibraryServing {
    private let api: any RomMClient
    private let credentialStore: any CredentialStoring

    init(api: any RomMClient, credentialStore: any CredentialStoring) {
        self.api = api
        self.credentialStore = credentialStore
    }

    func systems(in session: ServerSession) async throws -> [LibrarySystem] {
        try await api.systems(
            at: session.serverURL,
            token: authenticationToken()
        )
    }

    func collections(in session: ServerSession) async throws -> [LibraryCollection] {
        try await api.collections(
            at: session.serverURL,
            token: authenticationToken()
        )
    }

    func games(
        in session: ServerSession,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) async throws -> GamePage {
        try await api.games(
            at: session.serverURL,
            token: authenticationToken(),
            matching: filter,
            searchTerm: searchTerm,
            offset: offset,
            limit: limit
        )
    }

    func artworkRequest(for game: GameSummary, in session: ServerSession) async throws -> URLRequest? {
        guard let coverURL = game.coverURL else {
            return nil
        }

        var request = URLRequest(url: coverURL)
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        if session.serverURL.hasSameOrigin(as: coverURL) {
            let token = try await authenticationToken()
            request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func authenticationToken() async throws -> ClientToken {
        guard let token = try await credentialStore.loadToken() else {
            throw LibraryServiceError.notAuthenticated
        }
        return token
    }
}

enum LibraryServiceError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        "OpenVault could not find the RomM client token. Reconnect the server and try again."
    }
}
