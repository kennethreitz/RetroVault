import Foundation
import Nuke

/// Dependencies assembled at the application boundary.
struct AppEnvironment: Sendable {
    let serverConnection: any ServerConnecting
    let library: any LibraryServing

    static func live() -> AppEnvironment {
        let api = URLSessionRomMClient()
        let credentials = ApplicationSupportCredentialStore()
        let configuration = UserDefaultsServerConfigurationStore()
        let libraryCache = SwiftDataLibraryCache()
        ImagePipeline.shared = ImagePipeline(
            configuration: .withDataCache(
                name: "org.kennethreitz.OpenVault.Artwork",
                sizeLimit: 512 * 1_024 * 1_024
            )
        )

        return AppEnvironment(
            serverConnection: ServerConnectionService(
                api: api,
                credentialStore: credentials,
                configurationStore: configuration,
                libraryCache: libraryCache
            ),
            library: RomMLibraryService(
                api: api,
                credentialStore: credentials,
                cache: libraryCache,
                purgeArtworkCache: {
                    ImagePipeline.shared.cache.removeAll()
                }
            )
        )
    }
}
