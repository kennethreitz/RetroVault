import AppKit
import SwiftUI

/// Local-only Switch setup. Keys and firmware stay in RetroVault's private
/// data root; they are never uploaded to RomM or included in a save bundle.
struct SwitchSettingsSection: View {
  @State private var status = SwitchInstallation.setupStatus
  @State private var message: String?
  @State private var errorMessage: String?

  var body: some View {
    Section("Nintendo Switch") {
      LabeledContent("Engine") {
        Text(status.engineInstalled ? "Ryubing (Ryujinx)" : "Not installed")
          .foregroundStyle(
            status.engineInstalled ? .primary : .secondary
          )
      }
      LabeledContent("prod.keys") {
        statusLabel(status.hasProductKeys)
      }
      LabeledContent("title.keys") {
        Text(status.hasTitleKeys ? "Installed" : "Optional")
          .foregroundStyle(.secondary)
      }
      LabeledContent("Firmware") {
        if status.hasFirmware {
          Text("Installed")
        } else {
          Text("Optional")
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Button("Choose prod.keys…") {
          chooseKeyFile(named: SwitchInstallation.productKeysFileName)
        }
        Button("Choose title.keys…") {
          chooseKeyFile(named: SwitchInstallation.titleKeysFileName)
        }
      }

      Button("Choose Firmware Folder or ZIP…") {
        chooseFirmware()
      }

      Text(
        """
        Ryubing is an optional external engine embedded by this build. If it \
        is missing, run Scripts/fetch-ryujinx-companion.sh and rebuild. \
        RetroVault launches it with a private data root, so your own Ryujinx \
        profile and saves are untouched. Import prod.keys, optional title.keys, \
        and firmware dumped from your own console. These files never leave \
        this Mac and are never uploaded to RomM.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let message {
        Label(message, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
  }

  private func statusLabel(_ installed: Bool) -> some View {
    Text(installed ? "Installed" : "Missing")
      .foregroundStyle(installed ? .primary : .secondary)
  }

  private var installation: SwitchInstallation {
    SwitchInstallation.available
      ?? SwitchInstallation(
        executableURL: URL(
          fileURLWithPath: "/Applications/Ryujinx.app/Contents/MacOS/Ryujinx"
        ),
        dataRootURL: SwitchInstallation.defaultDataRootURL
      )
  }

  private func chooseKeyFile(named fileName: String) {
    let panel = NSOpenPanel()
    panel.title = "Choose \(fileName)"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      if fileName == SwitchInstallation.productKeysFileName {
        try installation.installProductKeys(from: url)
      } else {
        try installation.installTitleKeys(from: url)
      }
      message = "Installed \(fileName)."
      errorMessage = nil
    } catch {
      message = nil
      errorMessage = error.localizedDescription
    }
    status = SwitchInstallation.setupStatus
  }

  private func chooseFirmware() {
    let panel = NSOpenPanel()
    panel.title = "Choose Switch firmware"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      try installation.installFirmware(from: url)
      message = "Installed Switch firmware."
      errorMessage = nil
    } catch {
      message = nil
      errorMessage = error.localizedDescription
    }
    status = SwitchInstallation.setupStatus
  }
}
