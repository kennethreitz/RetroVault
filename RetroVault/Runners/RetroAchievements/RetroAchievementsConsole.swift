import Foundation

/// Maps a RomM system name to the RetroAchievements console id rcheevos hashes with.
enum RetroAchievementsConsole {
  static func identifier(forSystemName name: String?) -> UInt32? {
    guard let name else {
      return nil
    }
    switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "game boy", "nintendo game boy":
      return 4
    case "game boy color", "nintendo game boy color":
      return 6
    case "game boy advance", "nintendo game boy advance":
      return 5
    case "nes", "famicom", "nintendo famicom",
      "nintendo entertainment system", "nintendo nes":
      return 7
    case "snes", "super famicom", "nintendo super famicom",
      "super nintendo", "super nintendo entertainment system",
      "nintendo super nintendo entertainment system":
      return 3
    case "nintendo 64", "n64":
      return 2
    case "nintendo ds", "nds":
      return 18
    case "gamecube", "nintendo gamecube", "nintendo game cube", "gcn", "ngc":
      return 16
    case "wii", "nintendo wii":
      return 19
    case "master system", "sega master system", "sega master system/mark iii":
      return 11
    case "game gear", "sega game gear":
      return 15
    case "sg-1000", "sega sg-1000":
      return 33
    case "genesis", "mega drive", "sega genesis", "sega mega drive",
      "sega mega drive/genesis":
      return 1
    case "sega cd", "mega cd", "sega mega cd":
      return 9
    case "sega 32x", "mega 32x":
      return 10
    case "dreamcast", "sega dreamcast":
      return 40
    case "playstation", "playstation 1", "sony playstation", "ps1", "psx":
      return 12
    case "playstation portable", "sony playstation portable", "psp":
      return 41
    case "pc engine", "nec pc engine", "turbografx-16", "turbografx 16",
      "turbo grafx 16", "turbografx-16/pc engine", "nec turbografx-16",
      "pc engine supergrafx", "supergrafx", "nec supergrafx":
      return 8
    case "pc engine cd", "pc engine cd-rom2", "pc engine cd-rom²",
      "turbografx-cd", "turbografx cd", "nec pc engine cd":
      return 76
    case "atari 2600":
      return 25
    case "atari 5200":
      return 50
    case "atari 7800":
      return 51
    case "virtual boy", "nintendo virtual boy":
      return 28
    case "neo geo pocket", "snk neo geo pocket",
      "neo geo pocket color", "snk neo geo pocket color":
      return 14
    case "wonderswan", "bandai wonderswan",
      "wonderswan color", "bandai wonderswan color":
      return 53
    case "pokemon mini", "pokémon mini", "nintendo pokemon mini",
      "nintendo pokémon mini":
      return 24
    case "colecovision", "coleco vision", "coleco colecovision":
      return 44
    case "arcade", "finalburn neo":
      return 27
    case "dos", "ms-dos", "pc":
      return 26
    case "arduboy":
      return 71
    default:
      return nil
    }
  }
}
