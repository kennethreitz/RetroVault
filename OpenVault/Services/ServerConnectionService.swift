import Foundation

protocol ServerConnecting: Sendable {
    func restoredSession() async throws -> ServerSession?
    func pair(serverURL: String, pairingCode: String) async throws -> ServerSession
    func disconnect() async throws
}

actor ServerConnectionService: ServerConnecting {
    private static let requiredScopes: Set<String> = [
        "assets.read",
        "assets.write",
        "collections.read",
        "collections.write",
        "firmware.read",
        "me.read",
        "platforms.read",
        "roms.read",
        "roms.write",
        "roms.user.write",
    ]

    private let api: any RomMClient
    private let credentialStore: any CredentialStoring
    private let configurationStore: any ServerConfigurationStoring
    private let libraryCache: (any LibraryCaching)?

    init(
        api: any RomMClient,
        credentialStore: any CredentialStoring,
        configurationStore: any ServerConfigurationStoring,
        libraryCache: (any LibraryCaching)? = nil
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.configurationStore = configurationStore
        self.libraryCache = libraryCache
    }

    func restoredSession() async throws -> ServerSession? {
        async let configuration = configurationStore.load()
        async let token = credentialStore.loadToken()

        guard let configuration = try await configuration, try await token != nil else {
            return nil
        }

        return ServerSession(
            serverURL: configuration.serverURL,
            username: configuration.username
        )
    }

    func pair(serverURL rawServerURL: String, pairingCode rawPairingCode: String) async throws -> ServerSession {
        let serverURL = try ServerURL(rawServerURL)
        let pairingCode = try PairingCode(rawPairingCode)

        try await api.verifyServer(at: serverURL)
        let token = try await api.exchange(pairingCode: pairingCode, at: serverURL)

        // Pairing codes are single-use, so preserve the token before making
        // another network request.
        try await credentialStore.save(token)

        let user = try await api.currentUser(at: serverURL, token: token)
        let missingScopes = Self.requiredScopes.subtracting(user.scopes)
        guard missingScopes.isEmpty else {
            throw ServerConnectionError.missingScopes(missingScopes.sorted())
        }

        let configuration = RemoteServerConfiguration(
            serverURL: serverURL,
            username: user.username
        )
        try await configurationStore.save(configuration)

        return ServerSession(serverURL: serverURL, username: user.username)
    }

    func disconnect() async throws {
        async let removeConfiguration: Void = configurationStore.remove()
        async let removeToken: Void = credentialStore.removeToken()
        _ = try await (removeConfiguration, removeToken)
        try await libraryCache?.removeAll()
    }
}

enum ServerConnectionError: LocalizedError, Equatable {
    case missingScopes([String])

    var errorDescription: String? {
        switch self {
        case let .missingScopes(scopes):
            "The paired token is missing these permissions: \(scopes.joined(separator: ", "))."
        }
    }
}
