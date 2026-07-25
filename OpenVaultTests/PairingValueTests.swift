import Foundation
import Testing

@testable import OpenVault

@Suite("Pairing values")
struct PairingValueTests {
    @Test("Accepts an eight-character alphanumeric pairing code")
    func acceptsPairingCode() throws {
        let code = try PairingCode("A1b2C3d4")
        #expect(code.value == "A1b2C3d4")
    }

    @Test("Rejects malformed pairing codes", arguments: [
        "1234",
        "123456789",
        "1234 5678",
        "ABCD-123",
        "ÅBCD1234",
    ])
    func rejectsMalformedPairingCode(input: String) {
        #expect(throws: PairingCodeError.invalid) {
            try PairingCode(input)
        }
    }

    @Test("Accepts a RomM client token")
    func acceptsClientToken() throws {
        let value = "rmm_" + String(repeating: "a", count: 64)
        let token = try ClientToken(rawValue: value)
        #expect(token.rawValue == value)
    }

    @Test("Rejects malformed client tokens")
    func rejectsMalformedClientToken() {
        #expect(throws: ClientTokenError.invalid) {
            try ClientToken(rawValue: "rmm_not-a-token")
        }
    }
}

@Suite("RomM API client", .serialized)
struct RomMAPIClientTests {
    @Test("Explains an expired pairing code")
    func explainsExpiredPairingCode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        StubURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/client-tokens/exchange")

            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let client = URLSessionRomMClient(session: session)

        do {
            _ = try await client.exchange(
                pairingCode: PairingCode("N4FDM5AQ"),
                at: ServerURL("https://romm.example.com")
            )
            Issue.record("Expected an expired pairing code to be rejected.")
        } catch let error as RomMAPIError {
            #expect(
                error.errorDescription
                    == "That pairing code is invalid or has expired. Generate a new code in RomM and try again."
            )
        }
    }

    @Test("Decodes systems, collections, and a filtered game page")
    func decodesLibraryResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let token = try ClientToken(rawValue: "rmm_" + String(repeating: "d", count: 64))

        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token.rawValue)")

            let json: String
            switch request.url?.path {
            case "/api/platforms":
                json = """
                [
                  {"id": 3, "display_name": "Empty System", "rom_count": 0},
                  {"id": 2, "display_name": "Super Nintendo", "rom_count": 120},
                  {"id": 1, "display_name": "Game Boy", "rom_count": 80}
                ]
                """
            case "/api/collections":
                json = """
                [{"id": 10, "name": "Favorites", "rom_count": 12}]
                """
            case "/api/collections/smart":
                json = """
                [{"id": 11, "name": "Recently Added", "rom_count": 20}]
                """
            case "/api/roms":
                guard
                    let url = request.url,
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else {
                    throw URLError(.badURL)
                }
                #expect(
                    components.queryItems?.contains(
                        URLQueryItem(name: "platform_ids", value: "2")
                    ) == true
                )
                #expect(
                    components.queryItems?.contains(
                        URLQueryItem(name: "search_term", value: "Chrono")
                    ) == true
                )
                #expect(
                    components.queryItems?.contains(
                        URLQueryItem(name: "limit", value: "60")
                    ) == true
                )
                json = """
                {
                  "items": [
                    {
                      "id": 42,
                      "platform_id": 2,
                      "platform_display_name": "Super Nintendo",
                      "fs_name_no_ext": "Chrono Trigger (USA)",
                      "name": "Chrono Trigger",
                      "path_cover_small": "/assets/romm/resources/chrono.webp",
                      "path_cover_large": null,
                      "url_cover": null
                    }
                  ],
                  "total": 1,
                  "limit": 60,
                  "offset": 0,
                  "char_index": {},
                  "rom_id_index": [42],
                  "filter_values": {}
                }
                """
            default:
                Issue.record("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                json = "{}"
            }

            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = URLSessionRomMClient(session: session)
        let serverURL = try ServerURL("https://romm.example.com")

        let systems = try await client.systems(at: serverURL, token: token)
        let collections = try await client.collections(at: serverURL, token: token)
        let page = try await client.games(
            at: serverURL,
            token: token,
            matching: .system(2),
            searchTerm: "Chrono",
            offset: 0,
            limit: 60
        )

        #expect(systems.map(\.name) == ["Empty System", "Game Boy", "Super Nintendo"])
        #expect(collections.count == 2)
        #expect(collections.contains { $0.id == .smart(11) })
        #expect(page.games.first?.name == "Chrono Trigger")
        #expect(
            page.games.first?.coverURL?.absoluteString
                == "https://romm.example.com/assets/romm/resources/chrono.webp"
        )
        #expect(page.hasMore == false)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
