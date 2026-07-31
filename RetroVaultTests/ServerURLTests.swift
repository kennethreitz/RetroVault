import Foundation
import Testing

@testable import RetroVault

@Suite("Server URL")
struct ServerURLTests {
    @Test("Normalizes a trailing API path")
    func normalizesAPIPath() throws {
        let serverURL = try ServerURL("https://romm.example.com/api/")
        #expect(serverURL.value.absoluteString == "https://romm.example.com")
        #expect(
            serverURL.endpoint("api/heartbeat").absoluteString
                == "https://romm.example.com/api/heartbeat"
        )
    }

    @Test("Preserves a reverse-proxy base path")
    func preservesBasePath() throws {
        let serverURL = try ServerURL("https://example.com/games/")
        #expect(
            serverURL.endpoint("api/heartbeat").absoluteString
                == "https://example.com/games/api/heartbeat"
        )
        #expect(
            serverURL.clientTokenManagementURL.absoluteString
                == "https://example.com/games/client-api-tokens"
        )
    }

    @Test("Accepts HTTP for a local server", arguments: [
        "http://localhost:8080",
        "http://romm:8080",
        "http://romm.local",
        "http://192.168.1.20:8080",
        "http://10.0.0.4",
    ])
    func acceptsLocalHTTP(input: String) throws {
        _ = try ServerURL(input)
    }

    @Test("Rejects HTTP for a public server")
    func rejectsPublicHTTP() {
        #expect(throws: ServerURLError.insecureRemoteServer) {
            try ServerURL("http://romm.example.com")
        }
    }

    @Test("Rejects credentials embedded in a URL")
    func rejectsEmbeddedCredentials() {
        #expect(throws: ServerURLError.invalid) {
            try ServerURL("https://user:password@romm.example.com")
        }
    }

    @Test("Resolves RomM resources and compares origins")
    func resolvesResourcesAndOrigins() throws {
        let serverURL = try ServerURL("https://romm.example.com")
        let localCover = try #require(serverURL.resourceURL(for: "/assets/covers/game.webp"))
        let timestampedCover = try #require(
            serverURL.resourceURL(for: "/assets/covers/game.webp?ts=2026-07-20 13:08:02")
        )
        let remoteCover = try #require(serverURL.resourceURL(for: "https://images.example.net/game.webp"))

        #expect(localCover.absoluteString == "https://romm.example.com/assets/covers/game.webp")
        #expect(
            timestampedCover.absoluteString
                == "https://romm.example.com/assets/covers/game.webp?ts=2026-07-20%2013:08:02"
        )
        #expect(serverURL.hasSameOrigin(as: localCover))
        #expect(!serverURL.hasSameOrigin(as: remoteCover))
        #expect(!serverURL.hasSameOrigin(as: URL(string: "http://romm.example.com/game.webp")!))
    }
}
