import Foundation
import Testing

@testable import RetroVault

@Suite("RetroAchievements presentation")
struct RetroAchievementsPresentationTests {
  @Test("Hides a ROM that RomM has not matched")
  func hidesUnmatchedGames() {
    let profile = RetroAchievementsProfile(
      username: "player",
      gamesByRetroAchievementsID: [:]
    )
    #expect(
      RetroAchievementsPresentation.make(
        catalog: nil,
        profileState: .loaded(profile)
      ) == nil
    )
    #expect(
      RetroAchievementsPresentation.make(
        catalog: RetroAchievementsCatalog(
          gameID: 1446,
          hashMatched: true,
          achievements: []
        ),
        profileState: .loaded(profile)
      ) == nil
    )
  }

  @Test("Shows the set and hides unlocks when no username is linked")
  func hidesUnlocksWithoutUsername() throws {
    let presentation = RetroAchievementsPresentation.make(
      catalog: sampleCatalog(),
      profileState: .loaded(.unlinked)
    )

    let resolved = try #require(presentation)
    #expect(resolved.rows.count == 2)
    #expect(resolved.showsPersonalProgress == false)
    #expect(resolved.earnedCount == nil)
    #expect(resolved.progressLabel == nil)
    #expect(resolved.rows.allSatisfy { $0.isEarned == false })
    #expect(resolved.pageURL.absoluteString == "https://retroachievements.org/game/1446")
    #expect(resolved.statusMessage?.contains("no RetroAchievements username") == true)
  }

  @Test("Matches unlocks by achievement id when badges collide")
  func matchesIdentifiedUnlocks() throws {
    let profile = RetroAchievementsProfile(
      username: "player",
      gamesByRetroAchievementsID: [
        1446: RetroAchievementsGameProgress(
          earnedCount: 1,
          earnedHardcoreCount: 1,
          maximumPoints: 10,
          highestAwardKind: "beaten-hardcore",
          mostRecentAwardedAt: "2014-03-01 00:00:00",
          unlocks: [
            RetroAchievementsUnlock(
              badgeName: "shared",
              achievementID: 20,
              earnedAt: "2014-03-01 00:00:00",
              hardcoreEarnedAt: "2014-03-01 00:00:00"
            )
          ]
        )
      ]
    )

    let presentation = try #require(
      RetroAchievementsPresentation.make(
        catalog: sampleCatalog(),
        profileState: .loaded(profile)
      )
    )

    #expect(presentation.showsPersonalProgress)
    #expect(presentation.earnedCount == 1)
    #expect(presentation.hardcoreEarnedCount == 1)
    #expect(presentation.progressLabel == "1/2")
    #expect(presentation.awardTitle == "Beaten (Hardcore)")
    #expect(presentation.rows.first { $0.id == 20 }?.isEarned == true)
    #expect(presentation.rows.first { $0.id == 10 }?.isEarned == false)
    #expect(presentation.rows.first { $0.id == 20 }?.isHardcore == true)
  }

  @Test("Falls back to the badge name for RomM 5.4 unlock records")
  func matchesLegacyBadgeUnlocks() {
    let unlock = RetroAchievementsUnlock(
      badgeName: "shared",
      achievementID: nil,
      earnedAt: "2013-10-15 12:30:00",
      hardcoreEarnedAt: nil
    )
    let first = sampleCatalog().achievements[0]
    let second = sampleCatalog().achievements[1]

    #expect(
      RetroAchievementsPresentation.matchingUnlock(
        for: first,
        in: [unlock]
      )?.earnedAt == "2013-10-15 12:30:00"
    )
    #expect(
      RetroAchievementsPresentation.matchingUnlock(
        for: second,
        in: [unlock]
      ) != nil
    )
    #expect(RetroAchievementsDate.date(from: unlock.earnedAt) != nil)
  }

  @Test("Counts a linked user with no synced unlocks as zero")
  func showsZeroWhenTheSetWasNeverPlayed() throws {
    let presentation = try #require(
      RetroAchievementsPresentation.make(
        catalog: sampleCatalog(),
        profileState: .loaded(
          RetroAchievementsProfile(
            username: "player",
            gamesByRetroAchievementsID: [:]
          )
        )
      )
    )

    #expect(presentation.earnedCount == 0)
    #expect(presentation.progressLabel == "0/2")
  }

  private func sampleCatalog() -> RetroAchievementsCatalog {
    RetroAchievementsCatalog(
      gameID: 1446,
      hashMatched: true,
      achievements: [
        RetroAchievement(
          id: 10,
          title: "First",
          summary: "Do the first thing",
          points: 5,
          badgeName: "shared",
          lockedBadgeURL: URL(string: "https://media.retroachievements.org/Badge/shared_lock.png"),
          unlockedBadgeURL: URL(string: "https://media.retroachievements.org/Badge/shared.png"),
          displayOrder: 1,
          kind: "progression"
        ),
        RetroAchievement(
          id: 20,
          title: "Second",
          summary: "Do the second thing",
          points: 10,
          badgeName: "shared",
          lockedBadgeURL: URL(string: "https://media.retroachievements.org/Badge/shared_lock.png"),
          unlockedBadgeURL: URL(string: "https://media.retroachievements.org/Badge/shared.png"),
          displayOrder: 2,
          kind: "win_condition"
        ),
      ]
    )
  }
}

@Suite("RetroAchievements library rows")
struct RetroAchievementsLibraryRowTests {
  @Test("Shows a fraction only when unlock progress is known")
  func formatsProgress() {
    let unmatched = sampleGame()
    #expect(unmatched.retroAchievementsColumnValue == "—")
    #expect(unmatched.retroAchievementsProgressLabel == nil)

    let setOnly = sampleGame(retroAchievementsID: 1446, retroAchievementsCount: 75)
    #expect(setOnly.retroAchievementsColumnValue == "—")

    let progressed = sampleGame(
      retroAchievementsID: 1446,
      retroAchievementsCount: 75,
      retroAchievementsEarnedCount: 12
    )
    #expect(progressed.retroAchievementsProgressLabel == "12/75")
    #expect(
      BigPictureGameRowPresentation.detail(
        releaseYear: 1995,
        isDownloaded: true,
        retroAchievements: progressed.retroAchievementsProgressLabel
      ) == "LOCAL · 1995 · RA 12/75"
    )
  }

  @Test("Applies synced progress and clears it when the username is removed")
  func appliesProfile() {
    let game = sampleGame(retroAchievementsID: 1446, retroAchievementsCount: 4)
    let linked = RetroAchievementsProfile(
      username: "player",
      gamesByRetroAchievementsID: [
        1446: RetroAchievementsGameProgress(
          earnedCount: 3,
          earnedHardcoreCount: 1,
          maximumPoints: 50,
          highestAwardKind: "mastered",
          mostRecentAwardedAt: nil,
          unlocks: []
        )
      ]
    )

    let annotated = game.applyingRetroAchievementsProgress(linked)
    #expect(annotated.retroAchievementsEarnedCount == 3)
    #expect(annotated.retroAchievementsHardcoreEarnedCount == 1)

    let absent = sampleGame(retroAchievementsID: 99, retroAchievementsCount: 4)
      .applyingRetroAchievementsProgress(linked)
    #expect(absent.retroAchievementsEarnedCount == 0)

    let cleared = annotated.applyingRetroAchievementsProgress(.unlinked)
    #expect(cleared.retroAchievementsEarnedCount == nil)
    #expect(cleared.retroAchievementsID == 1446)
  }

  @Test("Keeps cached unlock counts when a refreshed row has the same id")
  func preservesCachedProgress() {
    let previous = sampleGame(
      retroAchievementsID: 1446,
      retroAchievementsCount: 4,
      retroAchievementsEarnedCount: 2,
      retroAchievementsHardcoreEarnedCount: 1
    )
    let refreshed = sampleGame(
      retroAchievementsID: 1446,
      retroAchievementsCount: 5
    )
    let preserved = refreshed.preservingRetroAchievementsProgress(from: previous)
    #expect(preserved.retroAchievementsEarnedCount == 2)
    #expect(preserved.retroAchievementsCount == 5)

    let differentGame = sampleGame(retroAchievementsID: 8, retroAchievementsCount: 5)
    #expect(
      differentGame.preservingRetroAchievementsProgress(from: previous)
        .retroAchievementsEarnedCount == nil
    )
  }

  @Test("Decodes a cached game that predates RetroAchievements fields")
  func decodesLegacyGameDetails() throws {
    let details = mockGameDetails(id: 7)
    let data = try JSONEncoder().encode(details)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var stripped = object
    stripped.removeValue(forKey: "retroAchievements")
    let legacy = try JSONSerialization.data(withJSONObject: stripped)
    let decoded = try JSONDecoder().decode(GameDetails.self, from: legacy)
    #expect(decoded.id == 7)
    #expect(decoded.retroAchievements == nil)

    let summaryData = try JSONEncoder().encode(sampleGame())
    let summaryObject = try #require(
      JSONSerialization.jsonObject(with: summaryData) as? [String: Any]
    )
    var legacySummary = summaryObject
    legacySummary.removeValue(forKey: "retroAchievementsID")
    legacySummary.removeValue(forKey: "retroAchievementsCount")
    legacySummary.removeValue(forKey: "retroAchievementsEarnedCount")
    legacySummary.removeValue(forKey: "retroAchievementsHardcoreEarnedCount")
    let decodedSummary = try JSONDecoder().decode(
      GameSummary.self,
      from: JSONSerialization.data(withJSONObject: legacySummary)
    )
    #expect(decodedSummary.retroAchievementsID == nil)
    #expect(decodedSummary.retroAchievementsProgressLabel == nil)
  }

  private func sampleGame(
    retroAchievementsID: Int? = nil,
    retroAchievementsCount: Int? = nil,
    retroAchievementsEarnedCount: Int? = nil,
    retroAchievementsHardcoreEarnedCount: Int? = nil
  ) -> GameSummary {
    GameSummary(
      id: 42,
      name: "Chrono Trigger",
      systemID: 2,
      systemName: "Super Nintendo",
      coverURL: nil,
      retroAchievementsID: retroAchievementsID,
      retroAchievementsCount: retroAchievementsCount,
      retroAchievementsEarnedCount: retroAchievementsEarnedCount,
      retroAchievementsHardcoreEarnedCount: retroAchievementsHardcoreEarnedCount
    )
  }
}

@Suite("RomM RetroAchievements responses", .serialized)
struct RetroAchievementsAPITests {
  @Test("Decodes a RomM 5.4 user, set, and library count")
  func decodesRomMPayloads() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetroAchievementsStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "a", count: 64))
    let serverURL = try ServerURL("https://romm.example.com")
    defer { RetroAchievementsStubURLProtocol.handler = nil }

    RetroAchievementsStubURLProtocol.handler = { request in
      let json: String
      switch request.url?.path {
      case "/api/users/me":
        json = """
          {
            "id": 4,
            "username": "kenneth",
            "oauth_scopes": ["roms.read"],
            "ra_username": " Player ",
            "ra_progression": {
              "total": 1,
              "results": [
                {
                  "rom_ra_id": 1446,
                  "max_possible": 25,
                  "num_awarded": 1,
                  "num_awarded_hardcore": 0,
                  "highest_award_kind": "beaten-softcore",
                  "earned_achievements": [
                    {"id": "shared", "date": "2013-10-15 12:30:00"},
                    {"not": "an unlock"},
                    {
                      "id": "other",
                      "ra_id": 20,
                      "date": "2014-03-01 00:00:00",
                      "date_hardcore": "2014-03-01 01:00:00"
                    }
                  ]
                }
              ]
            }
          }
          """
      case "/api/roms":
        json = """
          {
            "items": [
              {
                "id": 42,
                "platform_id": 2,
                "platform_display_name": "Super Nintendo",
                "fs_name_no_ext": "Chrono Trigger",
                "name": "Chrono Trigger",
                "ra_id": 1446,
                "merged_ra_metadata": {
                  "hash_match": true,
                  "achievements": [
                    {"title": "First"},
                    {"title": "Second"}
                  ]
                }
              }
            ],
            "total": 1,
            "limit": 60,
            "offset": 0
          }
          """
      case "/api/roms/42":
        json = """
          {
            "id": 42,
            "platform_id": 2,
            "platform_display_name": "Super Nintendo",
            "name": "Chrono Trigger",
            "ra_id": 1446,
            "merged_ra_metadata": {
              "hash_match": true,
              "achievements": [
                {
                  "ra_id": 10,
                  "title": "First",
                  "description": "Do the first thing",
                  "points": 5,
                  "badge_id": "shared",
                  "badge_url_lock": "https://media.retroachievements.org/Badge/shared_lock.png",
                  "badge_url": "https://media.retroachievements.org/Badge/shared.png",
                  "display_order": 1,
                  "type": "progression"
                },
                {
                  "title": "Untitled row"
                }
              ]
            }
          }
          """
      default:
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

    let client = URLSessionRomMClient(session: session)
    let user = try await client.currentUser(at: serverURL, token: token)
    #expect(user.retroAchievements.username == "Player")
    #expect(user.retroAchievements.isLinked)
    let progress = try #require(user.retroAchievements.progress(for: 1446))
    #expect(progress.earnedCount == 1)
    #expect(progress.unlocks.count == 2)
    #expect(progress.unlocks.contains { $0.achievementID == 20 && $0.hardcoreEarnedAt != nil })

    let page = try await client.games(
      at: serverURL,
      token: token,
      matching: .allGames,
      searchTerm: nil,
      ordering: .name,
      offset: 0,
      limit: 60
    )
    #expect(page.games.first?.retroAchievementsID == 1446)
    #expect(page.games.first?.retroAchievementsCount == 2)

    let details = try await client.gameDetails(for: 42, at: serverURL, token: token)
    let catalog = try #require(details.retroAchievements)
    #expect(catalog.gameID == 1446)
    #expect(catalog.hashMatched == true)
    #expect(catalog.achievements.map(\.title) == ["First", "Untitled row"])
    #expect(catalog.achievements[0].points == 5)
    #expect(catalog.achievements[1].id < 0)
    #expect(
      catalog.pageURL?.absoluteString == "https://retroachievements.org/game/1446"
    )
  }

  @Test("Keeps the RomM user when RetroAchievements progression is unusable")
  func ignoresMalformedProgression() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetroAchievementsStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let token = try ClientToken(rawValue: "rmm_" + String(repeating: "b", count: 64))
    let serverURL = try ServerURL("https://romm.example.com")
    defer { RetroAchievementsStubURLProtocol.handler = nil }

    RetroAchievementsStubURLProtocol.handler = { request in
      let json = """
        {
          "id": 4,
          "username": "kenneth",
          "oauth_scopes": [],
          "ra_username": "",
          "ra_progression": ["not", "an", "object"]
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

    let user = try await URLSessionRomMClient(session: session).currentUser(
      at: serverURL,
      token: token
    )
    #expect(user.username == "kenneth")
    #expect(user.retroAchievements.isLinked == false)
    #expect(user.retroAchievements.gamesByRetroAchievementsID.isEmpty)
  }
}

private final class RetroAchievementsStubURLProtocol: URLProtocol, @unchecked Sendable {
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
