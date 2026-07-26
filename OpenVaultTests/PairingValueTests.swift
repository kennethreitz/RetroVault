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

  @Test(
    "Rejects malformed pairing codes",
    arguments: [
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

  @Test("Uses a stable unified-log subsystem")
  func usesStableLogSubsystem() {
    #expect(OpenVaultLog.subsystem == "org.kennethreitz.OpenVault")
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
          [{"id": 10, "name": "Favorites", "rom_count": 12, "rom_ids": [42]}]
          """
      case "/api/collections/smart":
        json = """
          [{"id": 11, "name": "Recently Added", "rom_count": 20, "rom_ids": [42]}]
          """
      case "/api/collections/virtual":
        let components = try #require(
          request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
          }
        )
        #expect(
          components.queryItems?.contains(
            URLQueryItem(name: "type", value: "all")
          ) == true
        )
        json = """
          [
            {
              "id": "virtual-chrono",
              "name": "Chrono",
              "type": "collection",
              "rom_count": 1,
              "rom_ids": [42]
            }
          ]
          """
      case "/api/roms/42":
        json = """
          {
            "id": 42,
            "platform_id": 2,
            "platform_display_name": "Super Nintendo",
            "fs_name": "Chrono Trigger (USA).sfc",
            "fs_name_no_ext": "Chrono Trigger (USA)",
            "fs_extension": "sfc",
            "fs_path": "roms/SNES",
            "fs_size_bytes": 4194304,
            "full_path": "roms/SNES/Chrono Trigger (USA).sfc",
            "name": "Chrono Trigger",
            "summary": "A time-spanning adventure.",
            "alternative_names": ["Chrono"],
            "path_cover_large": "/assets/romm/resources/chrono-big.webp?ts=2026-07-20 13:08:02",
            "merged_screenshots": ["/assets/romm/resources/chrono-screen.jpg"],
            "has_manual": true,
            "has_soundtrack": true,
            "is_identified": true,
            "missing_from_fs": false,
            "regions": ["USA"],
            "languages": ["English"],
            "tags": ["RPG"],
            "created_at": "2026-07-18T10:21:35+00:00",
            "updated_at": "2026-07-20T13:13:41+00:00",
            "igdb_id": 1234,
            "libretro_id": "chrono-libretro",
            "metadatum": {
              "genres": ["Role-playing"],
              "franchises": [],
              "collections": ["Chrono"],
              "companies": ["Square"],
              "game_modes": ["Single player"],
              "age_ratings": ["E"],
              "player_count": "1",
              "first_release_date": 795484800000,
              "average_rating": 92.5
            },
            "files": [
              {
                "id": 7,
                "file_name": "Chrono Trigger (USA).sfc",
                "file_path": "roms/SNES",
                "full_path": "roms/SNES/Chrono Trigger (USA).sfc",
                "file_size_bytes": 4194304,
                "category": "game",
                "is_top_level": true,
                "crc_hash": "deadbeef",
                "md5_hash": "md5",
                "sha1_hash": "sha1"
              }
            ],
            "rom_user": {
              "status": "finished",
              "last_played": "2026-07-25T17:51:19+00:00",
              "rating": 9,
              "difficulty": 2,
              "completion": 100,
              "backlogged": false,
              "now_playing": false,
              "hidden": false
            },
            "sibling_roms": [],
            "user_saves": [
              {
                "id": 101,
                "file_name": "Chrono Trigger.srm",
                "file_extension": "srm",
                "file_path": "saves/SNES",
                "full_path": "saves/SNES/Chrono Trigger.srm",
                "download_path": "/api/saves/101/content",
                "file_size_bytes": 32768,
                "missing_from_fs": false,
                "created_at": "2026-07-21T10:00:00+00:00",
                "updated_at": "2026-07-25T18:30:00+00:00",
                "emulator": "Snes9x",
                "slot": "autosave",
                "content_hash": "save-hash",
                "is_public": false,
                "screenshot": null
              },
              {
                "id": 102,
                "file_name": "Chrono Trigger Manual.srm",
                "file_extension": "srm",
                "file_path": "saves/SNES",
                "full_path": "saves/SNES/Chrono Trigger Manual.srm",
                "download_path": "/api/saves/102/content",
                "file_size_bytes": 32768,
                "missing_from_fs": false,
                "created_at": "2026-07-22T10:00:00+00:00",
                "updated_at": "2026-07-24T18:30:00+00:00",
                "emulator": null,
                "slot": null,
                "content_hash": null,
                "is_public": true,
                "screenshot": null
              }
            ],
            "user_states": [
              {
                "id": 201,
                "file_name": "Chrono Trigger.state",
                "file_extension": "state",
                "file_path": "states/SNES",
                "full_path": "states/SNES/Chrono Trigger.state",
                "download_path": "/api/states/201/content",
                "file_size_bytes": 1048576,
                "missing_from_fs": false,
                "created_at": "2026-07-23T10:00:00+00:00",
                "updated_at": "2026-07-25T19:00:00+00:00",
                "emulator": "Snes9x",
                "is_public": false,
                "screenshot": {
                  "download_path": "/api/screenshots/301/content"
                }
              }
            ],
            "user_screenshots": [],
            "user_collections": [{}],
            "all_user_notes": []
          }
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
        #expect(
          components.queryItems?.contains(where: { $0.name == "tags" })
            == false
        )
        #expect(
          components.queryItems?.contains(where: { $0.name == "tags_logic" })
            == false
        )
        json = """
          {
            "items": [
              {
                "id": 40,
                "platform_id": 2,
                "platform_display_name": "Super Nintendo",
                "fs_name_no_ext": "[BIOS] Super Nintendo",
                "name": "Super Nintendo Firmware",
                "path_cover_small": null,
                "path_cover_large": null,
                "url_cover": null
              },
              {
                "id": 41,
                "platform_id": 2,
                "platform_display_name": "Super Nintendo",
                "fs_name_no_ext": "SNES Firmware",
                "name": "  [bios] SNES Firmware",
                "path_cover_small": null,
                "path_cover_large": null,
                "url_cover": null
              },
              {
                "id": 42,
                "platform_id": 2,
                "platform_display_name": "Super Nintendo",
                "fs_name_no_ext": "Chrono Trigger (USA)",
                "name": "Chrono Trigger",
                "path_cover_small": "/assets/romm/resources/chrono.webp",
                "path_cover_large": null,
                "url_cover": null,
                "fs_size_bytes": 4194304,
                "regions": ["USA"],
                "is_identified": true,
                "missing_from_fs": false,
                "created_at": "2026-07-18T10:21:35+00:00",
                "updated_at": "2026-07-20T13:13:41+00:00",
                "metadatum": {
                  "genres": ["Role-playing"],
                  "first_release_date": 795484800000
                },
                "rom_user": {
                  "status": "finished",
                  "rating": 9,
                  "difficulty": 2,
                  "completion": 100,
                  "backlogged": false,
                  "now_playing": false,
                  "hidden": false
                }
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
    let details = try await client.gameDetails(
      for: 42,
      at: serverURL,
      token: token
    )

    #expect(systems.map(\.name) == ["Empty System", "Game Boy", "Super Nintendo"])
    #expect(collections.count == 3)
    #expect(collections.contains { $0.id == .smart(11) })
    #expect(
      collections.contains {
        $0.id == .virtual("virtual-chrono")
          && $0.virtualType == "collection"
          && $0.memberGameIDs == [42]
      }
    )
    #expect(page.games.filter(\.isBIOS).count == 2)
    #expect(page.games.filter { !$0.isBIOS }.map(\.name) == ["Chrono Trigger"])
    #expect(page.games.first(where: { !$0.isBIOS })?.name == "Chrono Trigger")
    #expect(
      page.games.first(where: { !$0.isBIOS })?.coverURL?.absoluteString
        == "https://romm.example.com/assets/romm/resources/chrono.webp"
    )
    #expect(page.games.first(where: { !$0.isBIOS })?.userStatus == "finished")
    #expect(page.games.first(where: { !$0.isBIOS })?.completion == 100)
    #expect(page.games.first(where: { !$0.isBIOS })?.rating == 9)
    #expect(page.games.first(where: { !$0.isBIOS })?.genres == ["Role-playing"])
    #expect(page.games.first(where: { !$0.isBIOS })?.releaseYear == 1995)
    #expect(page.games.first(where: { !$0.isBIOS })?.regions == ["USA"])
    #expect(page.games.first(where: { !$0.isBIOS })?.fileSizeBytes == 4_194_304)
    #expect(page.games.first(where: { !$0.isBIOS })?.isIdentified == true)
    #expect(
      page.games.first(where: { !$0.isBIOS })?.createdAt
        == "2026-07-18T10:21:35+00:00"
    )
    #expect(page.hasMore == false)
    #expect(details.name == "Chrono Trigger")
    #expect(details.files.first?.name == "Chrono Trigger (USA).sfc")
    #expect(details.metadata.genres == ["Role-playing"])
    #expect(details.contentCounts.saves == 2)
    #expect(details.saves.first?.slot == "autosave")
    #expect(details.saves.first?.updatedAt != nil)
    #expect(
      details.states.first?.screenshotURL?.absoluteString
        == "https://romm.example.com/api/screenshots/301/content"
    )
    #expect(details.providerIdentifiers.contains { $0.name == "IGDB" && $0.value == "1234" })
    #expect(
      details.coverURL?.absoluteString
        == "https://romm.example.com/assets/romm/resources/chrono-big.webp?ts=2026-07-20%2013:08:02"
    )
  }

  @Test("Filters games with a RomM smart collection")
  func filtersSmartCollection() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "c", count: 64))

    StubURLProtocol.handler = { request in
      let components = try #require(
        request.url.flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
      )
      let queryItems = components.queryItems ?? []
      #expect(
        queryItems.contains(
          URLQueryItem(name: "smart_collection_id", value: "11")
        )
      )
      #expect(!queryItems.contains { $0.name == "collection_id" })

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let json = """
        {
          "items": [
            {
              "id": 42,
              "platform_id": 2,
              "platform_display_name": "Super Nintendo",
              "fs_name_no_ext": "Chrono Trigger",
              "name": "Chrono Trigger",
              "path_cover_small": null,
              "path_cover_large": null,
              "url_cover": null
            }
          ],
          "total": 1,
          "limit": 60,
          "offset": 0
        }
        """
      return (response, Data(json.utf8))
    }
    defer { StubURLProtocol.handler = nil }

    let page = try await URLSessionRomMClient(session: session).games(
      at: ServerURL("https://romm.example.com"),
      token: token,
      matching: .collection(.smart(11)),
      searchTerm: nil,
      offset: 0,
      limit: 60
    )

    #expect(page.games.map(\.id) == [42])
  }

  @Test("Filters games with a RomM virtual collection")
  func filtersVirtualCollection() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))

    StubURLProtocol.handler = { request in
      let components = try #require(
        request.url.flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
      )
      let queryItems = components.queryItems ?? []
      #expect(
        queryItems.contains(
          URLQueryItem(name: "virtual_collection_id", value: "virtual-chrono")
        )
      )
      #expect(!queryItems.contains { $0.name == "collection_id" })
      #expect(!queryItems.contains { $0.name == "smart_collection_id" })

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let json = """
        {
          "items": [
            {
              "id": 42,
              "platform_id": 2,
              "platform_display_name": "Super Nintendo",
              "fs_name_no_ext": "Chrono Trigger",
              "name": "Chrono Trigger",
              "path_cover_small": null,
              "path_cover_large": null,
              "url_cover": null
            }
          ],
          "total": 1,
          "limit": 60,
          "offset": 0
        }
        """
      return (response, Data(json.utf8))
    }
    defer { StubURLProtocol.handler = nil }

    let page = try await URLSessionRomMClient(session: session).games(
      at: ServerURL("https://romm.example.com"),
      token: token,
      matching: .collection(.virtual("virtual-chrono")),
      searchTerm: nil,
      offset: 0,
      limit: 60
    )

    #expect(page.games.map(\.id) == [42])
  }

  @Test("Fetches save and state availability with RomM filters")
  func fetchesSaveDataAvailability() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "e", count: 64))

    StubURLProtocol.handler = { request in
      let components = try #require(
        request.url.flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
      )
      let queryItems = components.queryItems ?? []
      let isSaveRequest = queryItems.contains(
        URLQueryItem(name: "has_saves", value: "true")
      )
      let isStateRequest = queryItems.contains(
        URLQueryItem(name: "has_states", value: "true")
      )
      #expect(isSaveRequest != isStateRequest)
      #expect(
        queryItems.contains(URLQueryItem(name: "limit", value: "500"))
      )

      let id = isSaveRequest ? 42 : 43
      let json = """
        {
          "items": [
            {
              "id": \(id),
              "platform_id": 2,
              "platform_display_name": "Super Nintendo",
              "fs_name_no_ext": "Game \(id)",
              "name": "Game \(id)",
              "path_cover_small": null,
              "path_cover_large": null,
              "url_cover": null
            }
          ],
          "total": 1,
          "limit": 500,
          "offset": 0
        }
        """
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

    #expect(
      try await client.gameIDsWithSaveData(
        .save,
        at: serverURL,
        token: token
      ) == [42]
    )
    #expect(
      try await client.gameIDsWithSaveData(
        .state,
        at: serverURL,
        token: token
      ) == [43]
    )
  }

  @Test("Streams a ROM from the authenticated content endpoint")
  func downloadsROM() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))
    let contents = Data("test rom contents".utf8)

    StubURLProtocol.handler = { request in
      #expect(
        request.url?.path
          == "/api/roms/42/content/Chrono Trigger (USA).sfc"
      )
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )
      #expect(
        request.value(forHTTPHeaderField: "Accept")?
          .contains("application/octet-stream") == true
      )

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
          "Content-Disposition": "attachment; filename=\"Chrono Trigger (USA).sfc\"",
          "Content-Length": String(contents.count),
          "Content-Type": "application/octet-stream",
        ]
      )!
      return (response, contents)
    }
    defer { StubURLProtocol.handler = nil }

    let client = URLSessionRomMClient(session: session)
    let progressRecorder = DownloadProgressRecorder()
    let download = try await client.downloadGame(
      for: 42,
      fileName: "Chrono Trigger (USA).sfc",
      at: ServerURL("https://romm.example.com"),
      token: token,
      onProgress: { progressRecorder.append($0) }
    )
    defer {
      try? FileManager.default.removeItem(at: download.temporaryFileURL)
    }

    #expect(download.suggestedFileName == "Chrono Trigger (USA).sfc")
    #expect(try Data(contentsOf: download.temporaryFileURL) == contents)
    let progress = progressRecorder.snapshot()
    #expect(progress.first?.bytesReceived == 0)
    #expect(progress.last?.bytesReceived == Int64(contents.count))
    #expect(progress.last?.totalBytesExpected == Int64(contents.count))
    #expect(progress.last?.fractionCompleted == 1)
  }

  @Test("Lists and downloads system firmware from RomM")
  func downloadsFirmware() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(
      rawValue: "rmm_" + String(repeating: "a", count: 64)
    )
    let contents = Data("firmware contents".utf8)

    StubURLProtocol.handler = { request in
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/octet-stream"]
      )!
      switch request.url?.path {
      case "/api/firmware":
        let components = try #require(
          request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
          }
        )
        #expect(
          components.queryItems?.contains(
            URLQueryItem(name: "platform_id", value: "12")
          ) == true
        )
        let json = """
          [{
            "id": 9,
            "file_name": "bios.test",
            "file_size_bytes": \(contents.count),
            "sha1_hash": "8b19e21435b673a82d392dcb36d0d65cb8c8f9c8",
            "is_verified": true,
            "missing_from_fs": false
          }]
          """
        return (response, Data(json.utf8))
      case "/api/firmware/9/content/bios.test":
        return (response, contents)
      default:
        Issue.record("Unexpected firmware request: \(request.url?.absoluteString ?? "")")
        return (response, Data())
      }
    }
    defer { StubURLProtocol.handler = nil }

    let client = URLSessionRomMClient(session: session)
    let firmware = try #require(
      try await client.firmware(
        for: 12,
        at: ServerURL("https://romm.example.com"),
        token: token
      ).first
    )
    #expect(firmware.fileName == "bios.test")

    let download = try await client.downloadFirmware(
      firmware,
      at: ServerURL("https://romm.example.com"),
      token: token
    )
    defer {
      try? FileManager.default.removeItem(at: download.temporaryFileURL)
    }
    #expect(try Data(contentsOf: download.temporaryFileURL) == contents)
  }

  @Test("Downloads an authenticated RomM cartridge save")
  func downloadsCartridgeSave() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "a", count: 64))
    let contents = Data(repeating: 0x42, count: 2_048)
    let serverURL = try ServerURL("https://romm.example.com")
    let save = GameSaveDataItem(
      id: 142,
      kind: .save,
      fileName: "Super Mario World.srm",
      fileExtension: "srm",
      filePath: "saves/SNES",
      fullPath: "saves/SNES/Super Mario World.srm",
      downloadURL: serverURL.resourceURL(for: "/api/saves/142/content"),
      fileSizeBytes: Int64(contents.count),
      isMissingFromFileSystem: false,
      createdAt: nil,
      updatedAt: nil,
      emulator: "Snes9x",
      slot: "autosave",
      contentHash: nil,
      isPublic: false,
      screenshotURL: nil
    )

    StubURLProtocol.handler = { request in
      #expect(request.url?.path == "/api/saves/142/content")
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )
      #expect(
        request.value(forHTTPHeaderField: "Accept")?
          .contains("application/octet-stream") == true
      )

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
          "Content-Disposition": "attachment; filename=\"Super Mario World.srm\"",
          "Content-Type": "application/octet-stream",
        ]
      )!
      return (response, contents)
    }
    defer { StubURLProtocol.handler = nil }

    let download = try await URLSessionRomMClient(session: session)
      .downloadSave(save, at: serverURL, token: token)
    defer {
      try? FileManager.default.removeItem(at: download.temporaryFileURL)
    }

    #expect(download.suggestedFileName == "Super Mario World.srm")
    #expect(try Data(contentsOf: download.temporaryFileURL) == contents)
  }

  @Test("Uploads a changed cartridge save as a bounded RomM autosave revision")
  func uploadsCartridgeSave() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "b", count: 64))
    let contents = Data(repeating: 0x7A, count: 2_048)

    StubURLProtocol.handler = { request in
      #expect(request.url?.path == "/api/saves")
      #expect(request.httpMethod == "POST")
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )

      let components = try #require(
        request.url.flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
      )
      let queryItems = components.queryItems ?? []
      #expect(queryItems.contains(URLQueryItem(name: "rom_id", value: "1175")))
      #expect(queryItems.contains(URLQueryItem(name: "emulator", value: "OpenVault")))
      #expect(queryItems.contains(URLQueryItem(name: "slot", value: "autosave")))
      #expect(queryItems.contains(URLQueryItem(name: "overwrite", value: "false")))
      #expect(queryItems.contains(URLQueryItem(name: "autocleanup", value: "true")))
      #expect(
        queryItems.contains(
          URLQueryItem(name: "autocleanup_limit", value: "10")
        )
      )

      let body = try requestBodyData(request)
      let bodyText = try #require(String(data: body, encoding: .isoLatin1))
      #expect(bodyText.contains("name=\"saveFile\""))
      #expect(bodyText.contains("filename=\"Super Mario World.srm\""))
      #expect(body.range(of: contents) != nil)

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let json = """
        {
          "id": 143,
          "rom_id": 1175,
          "user_id": 1,
          "file_name": "Super Mario World [2026-07-26_02-00-00].srm",
          "file_name_no_tags": "Super Mario World.srm",
          "file_name_no_ext": "Super Mario World",
          "file_extension": "srm",
          "file_path": "saves/SNES",
          "file_size_bytes": 2048,
          "full_path": "saves/SNES/Super Mario World.srm",
          "download_path": "/api/saves/143/content",
          "missing_from_fs": false,
          "created_at": "2026-07-26T02:00:00Z",
          "updated_at": "2026-07-26T02:00:00Z",
          "emulator": "OpenVault",
          "slot": "autosave",
          "content_hash": "hash",
          "is_public": false,
          "screenshot": null
        }
        """
      return (response, Data(json.utf8))
    }
    defer { StubURLProtocol.handler = nil }

    let uploaded = try await URLSessionRomMClient(session: session)
      .uploadSave(
        contents,
        fileName: "Super Mario World.srm",
        for: 1175,
        emulator: "OpenVault",
        slot: "autosave",
        at: ServerURL("https://romm.example.com"),
        token: token
      )

    #expect(uploaded.id == 143)
    #expect(uploaded.kind == .save)
    #expect(uploaded.fileSizeBytes == Int64(contents.count))
    #expect(uploaded.emulator == "OpenVault")
  }

  @Test("Deletes selected games with an explicit filesystem choice")
  func deletesSelectedGames() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))

    StubURLProtocol.handler = { request in
      #expect(request.url?.path == "/api/roms/delete")
      #expect(request.httpMethod == "POST")
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

      let body = try requestBodyData(request)
      let json = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      #expect(json["roms"] as? [Int] == [42, 43])
      #expect(json["delete_from_fs"] as? [Int] == [42, 43])

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let responseBody = """
        {
          "successful_items": 2,
          "failed_items": 0,
          "errors": []
        }
        """
      return (response, Data(responseBody.utf8))
    }
    defer { StubURLProtocol.handler = nil }

    let result = try await URLSessionRomMClient(session: session).deleteGames(
      withIDs: [42, 43],
      deletingFiles: true,
      at: ServerURL("https://romm.example.com"),
      token: token
    )

    #expect(result.successfulItemCount == 2)
    #expect(result.completedWithoutErrors)
  }

  @Test("Explains a stale RomM file record")
  func explainsUnavailableROMFile() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "f", count: 64))

    StubURLProtocol.handler = { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 404,
        httpVersion: nil,
        headerFields: [
          "Content-Disposition": "attachment; filename=\"Tetris.gb\"",
          "Content-Type": "text/html",
        ]
      )!
      return (response, Data())
    }
    defer { StubURLProtocol.handler = nil }

    let client = URLSessionRomMClient(session: session)

    do {
      _ = try await client.downloadGame(
        for: 39,
        fileName: "Tetris.gb",
        at: ServerURL("https://romm.example.com"),
        token: token
      )
      Issue.record("Expected the stale file record to be rejected.")
    } catch let error as RomMAPIError {
      #expect(
        error.errorDescription
          == "RomM found this game, but its ROM file is unavailable. The server's library record may be out of sync with its filesystem."
      )
    }
  }

  @Test("Updates per-user game metadata")
  func updatesGameUserMetadata() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "a", count: 64))

    StubURLProtocol.handler = { request in
      #expect(request.url?.path == "/api/roms/42/props")
      #expect(request.httpMethod == "PUT")
      #expect(
        request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(token.rawValue)"
      )
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

      let body = try requestBodyData(request)
      let json = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      #expect(json["status"] is NSNull)
      #expect(json["completion"] as? Int == 75)
      #expect(json["rating"] as? Int == 9)
      #expect(json["difficulty"] as? Int == 6)
      #expect(json["backlogged"] as? Bool == true)
      #expect(json["now_playing"] as? Bool == false)
      #expect(json["hidden"] as? Bool == false)

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      let responseBody = """
        {
          "status": null,
          "last_played": "2026-07-25T12:00:00Z",
          "completion": 75,
          "rating": 9,
          "difficulty": 6,
          "backlogged": true,
          "now_playing": false,
          "hidden": false
        }
        """
      return (response, Data(responseBody.utf8))
    }
    defer { StubURLProtocol.handler = nil }

    let client = URLSessionRomMClient(session: session)
    let updated = try await client.updateGameUserMetadata(
      GameUserMetadata(
        status: nil,
        lastPlayed: nil,
        rating: 9,
        difficulty: 6,
        completion: 75,
        isBacklogged: true,
        isNowPlaying: false,
        isHidden: false
      ),
      for: 42,
      at: ServerURL("https://romm.example.com"),
      token: token
    )

    #expect(updated.status == nil)
    #expect(updated.lastPlayed == "2026-07-25T12:00:00Z")
    #expect(updated.completion == 75)
    #expect(updated.rating == 9)
    #expect(updated.difficulty == 6)
    #expect(updated.isBacklogged)
  }
}

private final class DownloadProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RomMDownloadProgress] = []

  func append(_ progress: RomMDownloadProgress) {
    lock.lock()
    values.append(progress)
    lock.unlock()
  }

  func snapshot() -> [RomMDownloadProgress] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody {
    return body
  }

  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }

  var data = Data()
  let bufferSize = 4_096
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  defer { buffer.deallocate() }

  while stream.hasBytesAvailable {
    let count = stream.read(buffer, maxLength: bufferSize)
    guard count >= 0 else {
      throw stream.streamError ?? URLError(.cannotDecodeContentData)
    }
    if count == 0 {
      break
    }
    data.append(buffer, count: count)
  }

  return data
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

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
