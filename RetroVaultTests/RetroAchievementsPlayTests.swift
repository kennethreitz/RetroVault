import Foundation
import Testing

@testable import RetroVault

@Suite("RetroAchievements play rules")
struct RetroAchievementsPlayTests {
  @Test("Names RetroVault in the user agent")
  func identifiesTheClient() {
    let agent = RetroAchievementsUserAgent.product(version: "2026.8.17.1")
    #expect(agent == "RetroVault/2026.8.17.1")
    #expect(!agent.localizedCaseInsensitiveContains("retroarch"))
    #expect(RetroAchievementsUserAgent.product(version: "  ") == "RetroVault/0")
    #expect(
      RetroAchievementsUserAgent.gameplay(
        version: "2026.8.17.1",
        coreID: "libretro-gambatte",
        rcheevosClause: "rcheevos/12.4"
      ).hasPrefix("RetroVault/2026.8.17.1 (macOS ")
    )
    #expect(
      RetroAchievementsUserAgent.gameplay(
        version: "2026.8.17.1",
        coreID: "libretro-gambatte",
        rcheevosClause: "rcheevos/12.4"
      ).contains("libretro-gambatte rcheevos/12.4")
    )
  }

  @Test("Hardcore stays off and blocks the restricted features")
  func hardcoreDefaultsOff() {
    let defaults = UserDefaults(suiteName: "RetroAchievementsPlayTests.hardcore")!
    defaults.removePersistentDomain(
      forName: "RetroAchievementsPlayTests.hardcore"
    )
    #expect(RetroAchievementsHardcore.isEnabled(defaults: defaults) == false)
    #expect(
      RetroAchievementsHardcorePolicy.allowsSaveStateLoading(hardcoreEnabled: false)
    )
    #expect(
      RetroAchievementsHardcorePolicy.allowsSaveStateWriting(hardcoreEnabled: false)
    )
    #expect(RetroAchievementsHardcorePolicy.allowsRewind(hardcoreEnabled: false))
    #expect(
      RetroAchievementsHardcorePolicy.allowsFastForward(hardcoreEnabled: false)
    )
    #expect(RetroAchievementsHardcorePolicy.allowsSlowMotion(hardcoreEnabled: false))
    #expect(RetroAchievementsHardcorePolicy.allowsCheats(hardcoreEnabled: false))

    #expect(
      !RetroAchievementsHardcorePolicy.allowsSaveStateLoading(hardcoreEnabled: true)
    )
    #expect(
      !RetroAchievementsHardcorePolicy.allowsSaveStateWriting(hardcoreEnabled: true)
    )
    #expect(!RetroAchievementsHardcorePolicy.allowsRewind(hardcoreEnabled: true))
    #expect(!RetroAchievementsHardcorePolicy.allowsFastForward(hardcoreEnabled: true))
    #expect(!RetroAchievementsHardcorePolicy.allowsSlowMotion(hardcoreEnabled: true))
    #expect(!RetroAchievementsHardcorePolicy.allowsCheats(hardcoreEnabled: true))
    #expect(!RetroAchievementsHardcorePolicy.allowsSpeedChange(hardcoreEnabled: true))
  }

  @Test("Maps playable systems onto RetroAchievements console ids")
  func mapsConsoles() {
    #expect(RetroAchievementsConsole.identifier(forSystemName: "Game Boy") == 4)
    #expect(
      RetroAchievementsConsole.identifier(forSystemName: "Super Nintendo") == 3
    )
    #expect(RetroAchievementsConsole.identifier(forSystemName: "PlayStation") == 12)
    #expect(RetroAchievementsConsole.identifier(forSystemName: "Nintendo DS") == 18)
    #expect(RetroAchievementsConsole.identifier(forSystemName: nil) == nil)
    #expect(
      RetroAchievementsConsole.identifier(forSystemName: "PlayStation Vita") == nil
    )
  }
}
