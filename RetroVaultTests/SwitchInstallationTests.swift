import Foundation
import Testing

@testable import RetroVault

@Suite("Switch engine")
struct SwitchInstallationTests {
  @Test("Maps Switch 1 names and rejects Switch 2")
  func systemNames() {
    #expect(SwitchInstallation.isSwitchSystemName("Nintendo Switch"))
    #expect(SwitchInstallation.isSwitchSystemName("switch"))
    #expect(SwitchInstallation.isSwitchSystemName("Nintendo Switch 1"))
    #expect(!SwitchInstallation.isSwitchSystemName("Nintendo Switch 2"))
    #expect(!SwitchInstallation.isSwitchSystemName("Switch 2"))
    #expect(!SwitchInstallation.isSwitchSystemName("Wii U"))
  }

  @Test("Resolves the base title id from RomM identity or file name")
  func titleIDResolution() {
    #expect(
      SwitchInstallation.titleID(
        saveTarget: "0100F4700B2E0000",
        titleID: "0100F4700B2E0800",
        fileName: "Game [0100F4700B2E0000][v0].nsp"
      ) == "0100f4700b2e0000"
    )
    #expect(
      SwitchInstallation.titleID(
        saveTarget: nil,
        titleID: "010015100B514000",
        fileName: "Game.nsp"
      ) == "010015100b514000"
    )
    #expect(
      SwitchInstallation.titleID(
        saveTarget: nil,
        titleID: nil,
        fileName: "Game [0100F4700B2E0000][v0].nsp"
      ) == "0100f4700b2e0000"
    )
    #expect(
      SwitchInstallation.titleID(
        saveTarget: "not-a-title-id",
        titleID: nil,
        fileName: "Game.nsp"
      ) == nil
    )
  }

  @Test("Builds isolated Ryujinx quick-launch arguments")
  func launchArguments() throws {
    let runtime = SwitchRuntime(
      executableURL: URL(fileURLWithPath: "/Applications/Ryujinx.app/Contents/MacOS/Ryujinx"),
      dataRootURL: URL(fileURLWithPath: "/tmp/RetroVault/Switch/Ryujinx"),
      logURL: URL(fileURLWithPath: "/tmp/RetroVault/Switch/Ryujinx/Logs")
    )
    let content = URL(fileURLWithPath: "/tmp/Game [0100F4700B2E0000].nsp")

    let windowed = runtime.launchArguments(
      contentURL: content,
      presentation: .windowed
    )
    #expect(windowed.contains("-r"))
    #expect(windowed.contains(runtime.dataRootURL.path))
    #expect(windowed.contains("vulkan"))
    #expect(windowed.contains("--docked-mode"))
    #expect(!windowed.contains("-f"))
    #expect(windowed.last == content.path)

    let fullScreen = runtime.launchArguments(
      contentURL: content,
      presentation: .fullScreen
    )
    #expect(fullScreen.contains("-f"))
  }

  @Test("Installs keys and firmware into the private root")
  func installsSystemFiles() throws {
    let fixture = try SwitchFixture()
    defer { fixture.remove() }

    let keys = fixture.root.appending(path: "prod.keys")
    try "master_key_00 = 00000000000000000000000000000000\n"
      .write(to: keys, atomically: true, encoding: .utf8)
    try fixture.installation.installProductKeys(from: keys)

    let installedKeys = fixture.installation.productKeysURL
    #expect(FileManager.default.fileExists(atPath: installedKeys.path))
    let permissions = try FileManager.default.attributesOfItem(
      atPath: installedKeys.path
    )[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)

    let firmware = fixture.root.appending(
      path: "firmware/Contents/registered",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: firmware,
      withIntermediateDirectories: true
    )
    try Data([0x01]).write(
      to: firmware.appending(path: "0000000000000001.nca")
    )
    try fixture.installation.installFirmware(
      from: fixture.root.appending(path: "firmware")
    )
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.installation.firmwareDirectoryURL
          .appending(path: "0000000000000001.nca").path
      )
    )

    let wrapped = fixture.root.appending(
      path: "wrapped/registered",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: wrapped,
      withIntermediateDirectories: true
    )
    try Data([0x02]).write(
      to: wrapped.appending(path: "0000000000000002.nca")
    )
    try fixture.installation.installFirmware(
      from: fixture.root.appending(path: "wrapped")
    )
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.installation.firmwareDirectoryURL
          .appending(path: "0000000000000002.nca").path
      )
    )
  }

  @Test("Links the title save directory to the managed RomM bundle")
  func linksSaveDirectory() throws {
    let fixture = try SwitchFixture()
    defer { fixture.remove() }
    try fixture.installMinimumSystemFiles()

    let managed = fixture.root.appending(
      path: "managed-save",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: managed,
      withIntermediateDirectories: true
    )
    try Data([0x42]).write(to: managed.appending(path: "save.bin"))

    let configuration = CartridgeSaveSyncConfiguration(
      serverURL: try ServerURL("https://romm.example"),
      gameID: 7,
      localSaveURL: managed,
      uploadFileName: "Game.ryujinx.zip",
      emulator: "Ryujinx",
      slot: "autosave",
      storage: .directoryBundle
    )
    let titleID = "0100f4700b2e0000"

    _ = try fixture.installation.prepareRuntime(
      saveSync: configuration,
      titleID: titleID
    )

    let linked = fixture.installation.saveDirectoryURL(for: titleID)
    let destination = try FileManager.default.destinationOfSymbolicLink(
      atPath: linked.path
    )
    #expect(
      URL(fileURLWithPath: destination).standardizedFileURL
        == managed.appending(path: "title").standardizedFileURL
    )
    #expect(
      FileManager.default.fileExists(
        atPath: linked.appending(path: "save.bin").path
      )
    )
  }

  @Test("Projects device save data owned by the title")
  func linksDeviceSaveDirectory() throws {
    let fixture = try SwitchFixture()
    defer { fixture.remove() }
    try fixture.installMinimumSystemFiles()

    let titleID = "0100f2c0115b6000"
    let deviceID = "0000000000000001"
    let deviceDirectory = fixture.installation.dataRootURL
      .appending(path: "bis/user/save/\(deviceID)", directoryHint: .isDirectory)
      .appending(path: "0/slot_00", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: deviceDirectory,
      withIntermediateDirectories: true
    )
    try Data([0x42]).write(
      to: deviceDirectory.appending(path: "progress.sav")
    )

    var extraData = [UInt8](repeating: 0, count: 512)
    let owner = UInt64(titleID, radix: 16)!
    for index in 0..<8 {
      extraData[index] = UInt8((owner >> (8 * index)) & 0xFF)
    }
    try Data(extraData).write(
      to: fixture.installation.dataRootURL
        .appending(path: "bis/user/save/\(deviceID)/ExtraData0")
    )

    let managed = fixture.root.appending(
      path: "managed-device-save",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: managed,
      withIntermediateDirectories: true
    )
    let configuration = CartridgeSaveSyncConfiguration(
      serverURL: try ServerURL("https://romm.example"),
      gameID: 8,
      localSaveURL: managed,
      uploadFileName: "Game.ryujinx.zip",
      emulator: "Ryujinx",
      slot: "autosave",
      storage: .directoryBundle
    )

    _ = try fixture.installation.prepareRuntime(
      saveSync: configuration,
      titleID: titleID
    )

    let linked = fixture.installation.saveDirectoryURL(for: deviceID)
    let destination = try FileManager.default.destinationOfSymbolicLink(
      atPath: linked.path
    )
    #expect(
      URL(fileURLWithPath: destination).standardizedFileURL
        == managed.appending(path: "device/\(deviceID)").standardizedFileURL
    )
    #expect(
      FileManager.default.fileExists(
        atPath: linked.appending(path: "0/slot_00/progress.sav").path
      )
    )
  }
}

private struct SwitchFixture {
  let root: URL
  let installation: SwitchInstallation

  init() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "SwitchInstallationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let executable = root.appending(path: "Ryujinx")
    try Data().write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )

    self.root = root
    installation = SwitchInstallation(
      executableURL: executable,
      dataRootURL: root.appending(
        path: "data",
        directoryHint: .isDirectory
      )
    )
  }

  func installMinimumSystemFiles() throws {
    let keys = root.appending(path: "prod.keys")
    try "master_key_00 = 00\n".write(
      to: keys,
      atomically: true,
      encoding: .utf8
    )
    try installation.installProductKeys(from: keys)

    let firmware = root.appending(path: "firmware")
    try FileManager.default.createDirectory(
      at: firmware,
      withIntermediateDirectories: true
    )
    try Data([0x01]).write(
      to: firmware.appending(path: "0000000000000001.nca")
    )
    try installation.installFirmware(from: firmware)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
