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
      credentials(account)
      Toggle("Hardcore Mode", isOn: $hardcoreMode)
      caption(Self.hardcoreExplanation)
      if let statusMessage = account.statusMessage {
        caption(statusMessage)
      }
      caption(Self.sessionExplanation)
    }
    .task {
      await loadAccount(achievementsAccount)
    }
  }

  static let hardcoreExplanation = """
    Hardcore is off until you turn it on. While it is on, RetroVault \
    will not load save states, rewind, fast-forward, or slow down. A \
    save state can still be written, and it loads only after Hardcore \
    is off. RetroVault has no cheat system. RetroAchievements only \
    accepts hardcore unlocks after it verifies RetroVault as an emulator. \
    Until that review, the server can still record these unlocks as softcore.
    """

  static let sessionExplanation = """
    The password is sent to RetroAchievements to create a session and is \
    not saved. RetroVault keeps only that session token in the Keychain. \
    Sign-in applies the next time a game starts. Games without a matched \
    achievement set play as usual.
    """

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func credentials(_ source: RetroAchievementsAccount) -> some View {
    @Bindable var account = source
    if let username = account.signedInUsername {
      LabeledContent("Signed In", value: username)
      Button("Sign Out", role: .destructive) {
        account.signOut()
        password = ""
      }
    } else {
      signInFields(account)
    }
  }

  @ViewBuilder
  private func signInFields(_ source: RetroAchievementsAccount) -> some View {
    @Bindable var account = source
    TextField("Username", text: $account.usernameDraft)
      .textContentType(.username)
      .disabled(account.isWorking)

    SecureField("Password", text: $password)
      .textContentType(.password)
      .disabled(account.isWorking)

    Button(action: submitPassword) {
      signInLabel(isWorking: account.isWorking)
    }
    .disabled(account.isWorking)
  }

  private func signInLabel(isWorking: Bool) -> some View {
    Group {
      if isWorking {
        ProgressView()
          .controlSize(.small)
      } else {
        Text("Sign In")
      }
    }
  }

  private func submitPassword() {
    let submittedPassword = password
    password = ""
    Task {
      await achievementsAccount.signIn(password: submittedPassword)
    }
  }

  private func loadAccount(_ account: RetroAchievementsAccount) async {
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
