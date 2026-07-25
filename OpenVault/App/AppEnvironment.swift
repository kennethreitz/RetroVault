import Foundation

/// Dependencies assembled at the application boundary.
struct AppEnvironment: Sendable {
    let serverConnection: any ServerConnecting
    let library: any LibraryServing

    static func live() -> AppEnvironment {
        let api = URLSessionRomMClient()
        let credentials = KeychainCredentialStore()
        let configuration = UserDefaultsServerConfigurationStore()

        return AppEnvironment(
            serverConnection: ServerConnectionService(
                api: api,
                credentialStore: credentials,
                configurationStore: configuration
            ),
            library: RomMLibraryService(
                api: api,
                credentialStore: credentials
            )
        )
    }
}
