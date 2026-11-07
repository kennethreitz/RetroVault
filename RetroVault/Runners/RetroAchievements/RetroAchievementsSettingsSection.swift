import SwiftUI

struct RetroAchievementsSettingsSection: View {
  let model: AppModel
  @AppStorage(RetroAchievementsHardcore.enabledKey)
  private var hardcoreMode = false
  @State private var achievementsAccount = RetroAchievementsAccount.shared
  @State private var password = ""

  var body: some View {
    @Bindable var account = achievementsAccount
    Section("RetroAchievements") {
      if let username = account.signedInUsername {
        LabeledContent("Signed In", value: username)
        Button("Sign Out", role: .destructive) {
          account.signOut()
          password = ""
        }
      } else {
        TextField("Username", text: $account.usernameDraft)
          .textContentType(.username)
          .disabled(account.isWorking)

        SecureField("Password", text: $password)
          .textContentType(.password)
          .disabled(account.isWorking)

        Button {
          let submittedPassword = password
          password = ""
          Task {
            await account.signIn(password: submittedPassword)
          }
        } label: {
          if account.isWorking {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Sign In")
          }
        }
        .disabled(account.isWorking)
      }

      Toggle("Hardcore Mode", isOn: $hardcoreMode)

      Text(
        """
        Hardcore is off until you turn it on. While it is on, RetroVault \
        will not load save states, rewind, fast-forward, or slow down. A \
        save state can still be written, and it loads only after Hardcore \
        is off. RetroVault has no cheat system. RetroAchievements only \
        accepts hardcore unlocks after it verifies RetroVault as an emulator. \
        Until that review, the server can still record these unlocks as softcore.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let statusMessage = account.statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(
        """
        The password is sent to RetroAchievements to create a session and is \
        not saved. RetroVault keeps only that session token in the Keychain. \
        Sign-in applies the next time a game starts. Games without a matched \
        achievement set play as usual.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .task {
      account.refresh()
      guard case let .library(session) = model.destination else {
        return
      }
      let profile = try? await model.libraryService.retroAchievementsProfile(
        in: session
      )
      account.prefillUsername(profile?.username)
    }
  }
}
