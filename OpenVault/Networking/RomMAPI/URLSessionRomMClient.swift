import Foundation

final class URLSessionRomMClient: RomMClient, @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func verifyServer(at serverURL: ServerURL) async throws {
        let request = URLRequest(url: serverURL.endpoint("api/heartbeat"))
        _ = try await data(for: request)
    }

    func exchange(pairingCode: PairingCode, at serverURL: ServerURL) async throws -> ClientToken {
        var request = URLRequest(url: serverURL.endpoint("api/client-tokens/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(PairingCodeDTO(code: pairingCode.value))

        do {
            let data = try await data(for: request)
            let response = try decoder.decode(ClientTokenDTO.self, from: data)
            return try ClientToken(rawValue: response.rawToken)
        } catch RomMAPIError.notFound {
            // RomM returns 404 when a pairing code is unknown, expired, or
            // already consumed. The heartbeat check has already established
            // that this is a compatible RomM server.
            throw RomMAPIError.rejectedPairingCode
        } catch RomMAPIError.server(statusCode: 422) {
            throw RomMAPIError.rejectedPairingCode
        } catch is DecodingError {
            throw RomMAPIError.decoding(ClientTokenError.invalid)
        }
    }

    func currentUser(at serverURL: ServerURL, token: ClientToken) async throws -> RomMUser {
        var request = URLRequest(url: serverURL.endpoint("api/users/me"))
        authorize(&request, with: token)

        let data = try await data(for: request)
        do {
            let user = try decoder.decode(UserDTO.self, from: data)
            return RomMUser(
                id: user.id,
                username: user.username,
                scopes: Set(user.oauthScopes)
            )
        } catch {
            throw RomMAPIError.decoding(error)
        }
    }

    func systems(at serverURL: ServerURL, token: ClientToken) async throws -> [LibrarySystem] {
        var request = URLRequest(url: serverURL.endpoint("api/platforms"))
        authorize(&request, with: token)

        do {
            let data = try await data(for: request)
            return try decoder.decode([SystemDTO].self, from: data)
                .map {
                    LibrarySystem(
                        id: $0.id,
                        name: $0.displayName,
                        gameCount: $0.gameCount
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as RomMAPIError {
            throw error
        } catch {
            throw RomMAPIError.decoding(error)
        }
    }

    func collections(at serverURL: ServerURL, token: ClientToken) async throws -> [LibraryCollection] {
        async let regularData = authenticatedData(
            at: serverURL.endpoint("api/collections"),
            token: token
        )
        async let smartData = authenticatedData(
            at: serverURL.endpoint("api/collections/smart"),
            token: token
        )

        do {
            let (regular, smart) = try await (regularData, smartData)
            let regularCollections = try decoder.decode([CollectionDTO].self, from: regular)
                .map {
                    LibraryCollection(
                        id: .regular($0.id),
                        name: $0.name,
                        gameCount: $0.gameCount
                    )
                }
            let smartCollections = try decoder.decode([CollectionDTO].self, from: smart)
                .map {
                    LibraryCollection(
                        id: .smart($0.id),
                        name: $0.name,
                        gameCount: $0.gameCount
                    )
                }

            return (regularCollections + smartCollections)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as RomMAPIError {
            throw error
        } catch {
            throw RomMAPIError.decoding(error)
        }
    }

    func games(
        at serverURL: ServerURL,
        token: ClientToken,
        matching filter: LibraryFilter,
        searchTerm: String?,
        offset: Int,
        limit: Int
    ) async throws -> GamePage {
        var components = URLComponents(
            url: serverURL.endpoint("api/roms"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "with_char_index", value: "false"),
            URLQueryItem(name: "with_filter_values", value: "false"),
            URLQueryItem(name: "with_files", value: "false"),
            URLQueryItem(name: "order_by", value: "name"),
            URLQueryItem(name: "order_dir", value: "asc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]

        if let searchTerm, !searchTerm.isEmpty {
            queryItems.append(URLQueryItem(name: "search_term", value: searchTerm))
        }

        switch filter {
        case .allGames:
            break
        case let .system(id):
            queryItems.append(URLQueryItem(name: "platform_ids", value: String(id)))
        case let .collection(.regular(id)):
            queryItems.append(URLQueryItem(name: "collection_id", value: String(id)))
        case let .collection(.smart(id)):
            queryItems.append(URLQueryItem(name: "smart_collection_id", value: String(id)))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw RomMAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        authorize(&request, with: token)

        do {
            let data = try await data(for: request)
            let page = try decoder.decode(GamePageDTO.self, from: data)
            return GamePage(
                games: page.items.map { $0.gameSummary(serverURL: serverURL) },
                total: page.total,
                limit: page.limit,
                offset: page.offset
            )
        } catch let error as RomMAPIError {
            throw error
        } catch {
            throw RomMAPIError.decoding(error)
        }
    }

    private func authenticatedData(at url: URL, token: ClientToken) async throws -> Data {
        var request = URLRequest(url: url)
        authorize(&request, with: token)
        return try await data(for: request)
    }

    private func authorize(_ request: inout URLRequest, with token: ClientToken) {
        request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw RomMAPIError.transport(error)
        }

        guard let response = response as? HTTPURLResponse else {
            throw RomMAPIError.invalidResponse
        }

        switch response.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw RomMAPIError.unauthorized
        case 403:
            throw RomMAPIError.forbidden
        case 404:
            throw RomMAPIError.notFound
        default:
            throw RomMAPIError.server(statusCode: response.statusCode)
        }
    }
}

private struct PairingCodeDTO: Encodable {
    let code: String
}

private struct ClientTokenDTO: Decodable {
    let rawToken: String

    enum CodingKeys: String, CodingKey {
        case rawToken = "raw_token"
    }
}

private struct UserDTO: Decodable {
    let id: Int
    let username: String
    let oauthScopes: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case oauthScopes = "oauth_scopes"
    }
}

private struct SystemDTO: Decodable {
    let id: Int
    let displayName: String
    let gameCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case gameCount = "rom_count"
    }
}

private struct CollectionDTO: Decodable {
    let id: Int
    let name: String
    let gameCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gameCount = "rom_count"
    }
}

private struct GamePageDTO: Decodable {
    let items: [GameDTO]
    let total: Int
    let limit: Int
    let offset: Int
}

private struct GameDTO: Decodable {
    let id: Int
    let systemID: Int
    let systemName: String
    let fileNameWithoutExtension: String
    let name: String?
    let smallCoverPath: String?
    let largeCoverPath: String?
    let remoteCoverURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case systemID = "platform_id"
        case systemName = "platform_display_name"
        case fileNameWithoutExtension = "fs_name_no_ext"
        case name
        case smallCoverPath = "path_cover_small"
        case largeCoverPath = "path_cover_large"
        case remoteCoverURL = "url_cover"
    }

    func gameSummary(serverURL: ServerURL) -> GameSummary {
        let metadataName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = metadataName.flatMap { $0.isEmpty ? nil : $0 } ?? fileNameWithoutExtension
        let coverPath = [smallCoverPath, largeCoverPath, remoteCoverURL]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return GameSummary(
            id: id,
            name: displayName,
            systemID: systemID,
            systemName: systemName,
            coverURL: serverURL.resourceURL(for: coverPath)
        )
    }
}
