import AppKit
import SwiftUI

/// The immutable library context needed to open a native game information
/// window without changing the current library selection.
struct GameInfoRequest: Codable, Hashable {
  let game: GameSummary
  let lastLibrarySync: Date?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.game.id == rhs.game.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(game.id)
  }
}

/// An action supplied by the focused library view for the standard Get Info
/// command.
struct OpenGameInfoAction {
  private let action: @MainActor () -> Void

  init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  @MainActor
  func callAsFunction() {
    action()
  }
}

private struct OpenGameInfoFocusedValueKey: FocusedValueKey {
  typealias Value = OpenGameInfoAction
}

extension FocusedValues {
  var openGameInfo: OpenGameInfoAction? {
    get { self[OpenGameInfoFocusedValueKey.self] }
    set { self[OpenGameInfoFocusedValueKey.self] = newValue }
  }
}

struct GameInfoCommands: Commands {
  @FocusedValue(\.openGameInfo) private var openGameInfo

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()

      Button("Get Info") {
        openGameInfo?()
      }
      .keyboardShortcut("i", modifiers: .command)
      .disabled(openGameInfo == nil)
    }
  }
}

private enum GameInfoTab: String, CaseIterable, Identifiable {
  case general
  case files
  case saveData
  case metadata

  var id: Self { self }

  var title: String {
    switch self {
    case .general:
      "General"
    case .files:
      "Files"
    case .saveData:
      "Save Data"
    case .metadata:
      "Metadata"
    }
  }

  var systemImage: String {
    switch self {
    case .general:
      "info.circle"
    case .files:
      "doc.on.doc"
    case .saveData:
      "externaldrive.badge.timemachine"
    case .metadata:
      "list.bullet.rectangle"
    }
  }
}

/// A native, read-only inspector for all cached and server-backed information
/// associated with one RomM game.
struct GameInfoView: View {
  private let lastLibrarySync: Date?
  @State private var model: GameDetailsModel
  @State private var selectedTab = GameInfoTab.general

  init(
    request: GameInfoRequest,
    session: ServerSession,
    service: any LibraryServing
  ) {
    lastLibrarySync = request.lastLibrarySync
    _model = State(
      initialValue: GameDetailsModel(
        game: request.game,
        session: session,
        service: service
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Picker("Game Information", selection: $selectedTab) {
        ForEach(GameInfoTab.allCases) { tab in
          Label(tab.title, systemImage: tab.systemImage)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 24)
      .padding(.vertical, 14)

      Divider()

      content
    }
    .frame(minWidth: 720, minHeight: 560)
    .background(.background)
    .task {
      await model.load()
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 18) {
      GameCoverView(
        game: model.details?.gameSummary ?? model.game,
        session: model.session,
        service: model.service
      )
      .frame(width: 96, height: 128)
      .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(model.details?.name ?? model.game.name)
            .font(.title2.bold())
            .lineLimit(2)
            .textSelection(.enabled)

          Spacer(minLength: 16)

          Button {
            Task {
              await model.reload()
            }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(model.isLoading)
        }

        HStack(spacing: 8) {
          Label(
            model.details?.systemName ?? model.game.systemName,
            systemImage: "gamecontroller"
          )

          if let releaseDate = model.details?.metadata.firstReleaseDate {
            Text(
              releaseDate.formatted(
                date: .abbreviated,
                time: .omitted
              )
            )
          } else if let releaseYear = model.game.releaseYear {
            Text(String(releaseYear))
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        HStack(spacing: 7) {
          GameInfoBadge(
            title: metadataStatusTitle,
            systemImage: metadataStatusSystemImage,
            tint: metadataStatusTint
          )

          GameInfoBadge(
            title:
              model.isLocallyAvailable
              ? "Downloaded"
              : "Not Downloaded",
            systemImage:
              model.isLocallyAvailable
              ? "arrow.down.circle.fill"
              : "icloud",
            tint: model.isLocallyAvailable ? .blue : .secondary
          )

          if let details = model.details {
            GameInfoBadge(
              title: countLabel(details.saves.count, singular: "Save"),
              systemImage: "externaldrive.fill",
              tint: details.saves.isEmpty ? .secondary : .blue
            )
            GameInfoBadge(
              title: countLabel(details.states.count, singular: "State"),
              systemImage: "clock.arrow.circlepath",
              tint: details.states.isEmpty ? .secondary : .purple
            )
          }
        }

        if let refreshErrorMessage = model.refreshErrorMessage {
          Label(refreshErrorMessage, systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
            .help(refreshErrorMessage)
        }
      }
    }
    .padding(24)
  }

  @ViewBuilder
  private var content: some View {
    if let details = model.details {
      ScrollView {
        switch selectedTab {
        case .general:
          generalContent(details)
        case .files:
          filesContent(details)
        case .saveData:
          saveDataContent(details)
        case .metadata:
          metadataContent(details)
        }
      }
      .contentMargins(24, for: .scrollContent)
    } else if let errorMessage = model.errorMessage {
      ContentUnavailableView {
        Label(
          "Couldn’t Load Game Information",
          systemImage: "exclamationmark.triangle"
        )
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Try Again") {
          Task {
            await model.reload()
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView("Loading \(model.game.name)…")
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func generalContent(_ details: GameDetails) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      GameInfoSection("Sync Status", systemImage: "arrow.triangle.2.circlepath") {
        GameInfoFields(
          fields: [
            ("Metadata", metadataStatusTitle),
            (
              "Library Sync",
              lastLibrarySync?.formatted(
                date: .abbreviated,
                time: .standard
              ) ?? "Not yet synchronized"
            ),
            (
              "Local ROM",
              model.isDownloaded
                ? "Managed by RetroVault"
                : model.isLocallyAvailable
                  ? "Available locally"
                  : "Not downloaded"
            ),
            (
              "RomM Save Data",
              "\(details.saves.count.formatted()) saves, "
                + "\(details.states.count.formatted()) states"
            ),
          ]
        )
      }

      if let summary = nonempty(details.summary) {
        GameInfoSection("Description", systemImage: "text.alignleft") {
          Text(summary)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .textSelection(.enabled)
        }
      }

      GameInfoSection("Activity", systemImage: "chart.bar") {
        GameInfoFields(
          fields: [
            ("Status", humanized(details.userMetadata.status) ?? "Not Set"),
            (
              "Completion",
              "\(details.userMetadata.completion.formatted())%"
            ),
            (
              "Rating",
              details.userMetadata.rating > 0
                ? "\(details.userMetadata.rating)/10"
                : "Not Rated"
            ),
            (
              "Difficulty",
              details.userMetadata.difficulty > 0
                ? "\(details.userMetadata.difficulty)/10"
                : "Not Rated"
            ),
            (
              "Last Played",
              formatServerDate(details.userMetadata.lastPlayed) ?? "Never"
            ),
            (
              "Flags",
              activityFlags(details.userMetadata)
            ),
          ]
        )
      }

      GameInfoSection("Game", systemImage: "gamecontroller") {
        GameInfoFields(
          fields: [
            (
              "Release Date",
              details.metadata.firstReleaseDate?.formatted(
                date: .long,
                time: .omitted
              ) ?? "Unknown"
            ),
            ("Players", nonempty(details.metadata.playerCount) ?? "Unknown"),
            (
              "Average Rating",
              details.metadata.averageRating.map {
                $0.formatted(.number.precision(.fractionLength(1)))
              } ?? "Unknown"
            ),
            ("Regions", joined(details.regions)),
            ("Languages", joined(details.languages)),
            ("Genres", joined(details.metadata.genres)),
            ("Companies", joined(details.metadata.companies)),
            ("Franchises", joined(details.metadata.franchises)),
            ("Collections", joined(details.metadata.collections)),
            ("Game Modes", joined(details.metadata.gameModes)),
            ("Age Ratings", joined(details.metadata.ageRatings)),
            ("Tags", joined(details.tags)),
          ]
        )
      }

      GameInfoSection("Library Content", systemImage: "square.stack.3d.up") {
        GameInfoFields(
          fields: [
            ("Files", details.files.count.formatted()),
            ("Saves", details.saves.count.formatted()),
            ("Save States", details.states.count.formatted()),
            (
              "Screenshots",
              details.contentCounts.screenshots.formatted()
            ),
            ("Notes", details.contentCounts.notes.formatted()),
            (
              "Collections",
              details.contentCounts.collections.formatted()
            ),
            (
              "Sibling Games",
              details.contentCounts.siblingGames.formatted()
            ),
          ]
        )
      }
    }
    .padding(.bottom, 24)
  }

  private func filesContent(_ details: GameDetails) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if details.files.isEmpty {
        ContentUnavailableView(
          "No File Records",
          systemImage: "doc.badge.ellipsis",
          description: Text(
            "The cached library summary does not include RomM file records."
          )
        )
      } else {
        ForEach(details.files) { file in
          GameFileInfoView(file: file)
        }
      }
    }
    .padding(.bottom, 24)
  }

  private func saveDataContent(_ details: GameDetails) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      GameInfoSection("Save Synchronization", systemImage: "arrow.up.arrow.down") {
        Text(
          "These are the save files and save states currently recorded for "
            + "your RomM user. Items marked available can be fetched when "
            + "RetroVault prepares the game."
        )
        .foregroundStyle(.secondary)

        GameInfoFields(
          fields: [
            (
              "Connection",
              model.dataSource == .remote
                ? "RomM reachable"
                : "Using local cache"
            ),
            ("Saves on RomM", details.saves.count.formatted()),
            ("States on RomM", details.states.count.formatted()),
          ]
        )
      }

      GameInfoSection("Saves", systemImage: "externaldrive.fill") {
        if details.saves.isEmpty {
          Text("No saves are recorded in RomM.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(details.saves) { item in
            GameSaveDataInfoView(item: item)
          }
        }
      }

      GameInfoSection("Save States", systemImage: "clock.arrow.circlepath") {
        if details.states.isEmpty {
          Text("No save states are recorded in RomM.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(details.states) { item in
            GameSaveDataInfoView(item: item)
          }
        }
      }
    }
    .padding(.bottom, 24)
  }

  private func metadataContent(_ details: GameDetails) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      GameInfoSection("RomM Record", systemImage: "server.rack") {
        GameInfoFields(
          fields: [
            ("Game ID", details.id.formatted()),
            ("System ID", details.systemID.formatted()),
            ("System", details.systemName),
            ("File Name", valueOrUnknown(details.fileName)),
            ("Extension", valueOrUnknown(details.fileExtension)),
            ("File Size", byteCount(details.fileSizeBytes)),
            ("File Path", valueOrUnknown(details.filePath)),
            ("Full Path", valueOrUnknown(details.fullPath)),
            ("Revision", valueOrUnknown(details.revision)),
            (
              "Identified",
              details.isIdentified ? "Yes" : "No"
            ),
            (
              "Missing from Filesystem",
              details.isMissingFromFileSystem ? "Yes" : "No"
            ),
            ("Created", formatServerDate(details.createdAt) ?? "Unknown"),
            ("Updated", formatServerDate(details.updatedAt) ?? "Unknown"),
          ]
        )
      }

      GameInfoSection("Hashes", systemImage: "number") {
        GameInfoFields(
          fields: [
            ("CRC", valueOrUnknown(details.crcHash)),
            ("MD5", valueOrUnknown(details.md5Hash)),
            ("SHA-1", valueOrUnknown(details.sha1Hash)),
            (
              "RetroAchievements",
              valueOrUnknown(details.retroAchievementsHash)
            ),
          ]
        )
      }

      GameInfoSection("Media", systemImage: "photo.on.rectangle.angled") {
        GameInfoFields(
          fields: [
            (
              "Cover",
              details.coverURL?.absoluteString ?? "Unavailable"
            ),
            (
              "Screenshots",
              details.screenshotURLs.count.formatted()
            ),
            ("Manual", details.hasManual ? "Available" : "Unavailable"),
            (
              "Manual URL",
              details.manualURL?.absoluteString ?? "Unavailable"
            ),
            (
              "Soundtrack",
              details.hasSoundtrack ? "Available" : "Unavailable"
            ),
            (
              "Video URL",
              details.videoURL?.absoluteString ?? "Unavailable"
            ),
          ]
        )
      }

      GameInfoSection("Names and Providers", systemImage: "network") {
        GameInfoFields(
          fields: [
            ("Alternative Names", joined(details.alternativeNames)),
            (
              "Providers",
              details.providerIdentifiers.isEmpty
                ? "None"
                : details.providerIdentifiers.map {
                  "\($0.name): \($0.value)"
                }.joined(separator: "\n")
            ),
          ]
        )

        Link(
          destination: model.session.serverURL.endpoint(
            "rom/\(details.id)"
          )
        ) {
          Label("Open in RomM", systemImage: "arrow.up.right.square")
        }
      }
    }
    .padding(.bottom, 24)
  }

  private var metadataStatusTitle: String {
    switch model.dataSource {
    case .remote:
      "Synced with RomM"
    case .cachedDetails:
      "Cached Metadata"
    case .librarySummary:
      "Cached Summary"
    case .none:
      model.isLoading ? "Checking RomM" : "Unknown"
    }
  }

  private var metadataStatusSystemImage: String {
    switch model.dataSource {
    case .remote:
      "checkmark.circle.fill"
    case .cachedDetails, .librarySummary:
      "wifi.slash"
    case .none:
      "questionmark.circle"
    }
  }

  private var metadataStatusTint: Color {
    switch model.dataSource {
    case .remote:
      .green
    case .cachedDetails, .librarySummary:
      .orange
    case .none:
      .secondary
    }
  }

  private func countLabel(_ count: Int, singular: String) -> String {
    "\(count.formatted()) \(count == 1 ? singular : "\(singular)s")"
  }

  private func joined(_ values: [String]) -> String {
    values.isEmpty ? "None" : values.joined(separator: ", ")
  }

  private func activityFlags(_ metadata: GameUserMetadata) -> String {
    var flags: [String] = []
    if metadata.isNowPlaying {
      flags.append("Now Playing")
    }
    if metadata.isBacklogged {
      flags.append("Backlogged")
    }
    if metadata.isHidden {
      flags.append("Hidden")
    }
    return joined(flags)
  }

  private func nonempty(_ value: String?) -> String? {
    guard
      let value = value?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private func humanized(_ value: String?) -> String? {
    nonempty(value)?
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  private func valueOrUnknown(_ value: String?) -> String {
    nonempty(value) ?? "Unknown"
  }
}

private struct GameInfoBadge: View {
  let title: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(tint.opacity(0.12), in: Capsule())
  }
}

private struct GameInfoSection<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)

      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.55))
      .clipShape(.rect(cornerRadius: 12))
    }
  }
}

private struct GameInfoFields: View {
  let fields: [(String, String)]

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
      ForEach(Array(fields.enumerated()), id: \.offset) { entry in
        let field = entry.element
        GridRow {
          Text(field.0)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)

          Text(field.1)
            .textSelection(.enabled)
            .gridColumnAlignment(.leading)
        }
      }
    }
    .font(.callout)
  }
}

private struct GameFileInfoView: View {
  let file: GameFile

  var body: some View {
    DisclosureGroup {
      GameInfoFields(
        fields: [
          ("File ID", file.id.formatted()),
          ("Path", file.path),
          ("Full Path", file.fullPath),
          ("Size", byteCount(file.sizeBytes)),
          ("Category", file.category ?? "Unknown"),
          ("Top Level", file.isTopLevel ? "Yes" : "No"),
          ("Created", formatServerDate(file.createdAt) ?? "Unknown"),
          ("Updated", formatServerDate(file.updatedAt) ?? "Unknown"),
          (
            "Last Modified",
            formatServerDate(file.lastModified) ?? "Unknown"
          ),
          ("CRC", file.crcHash ?? "Unknown"),
          ("MD5", file.md5Hash ?? "Unknown"),
          ("SHA-1", file.sha1Hash ?? "Unknown"),
          (
            "RetroAchievements",
            file.retroAchievementsHash ?? "Unknown"
          ),
          ("CHD SHA-1", file.chdSHA1Hash ?? "Unknown"),
          (
            "Archive Members",
            file.archiveMembers.isEmpty
              ? "None"
              : file.archiveMembers.map(\.name).joined(separator: "\n")
          ),
        ]
      )

      if let track = file.trackMetadata {
        Divider()
        GameInfoFields(
          fields: [
            ("Track Title", track.title ?? "Unknown"),
            ("Artist", track.artist ?? "Unknown"),
            ("Album", track.album ?? "Unknown"),
            ("Year", track.year.map(String.init) ?? "Unknown"),
            ("Genre", track.genre ?? "Unknown"),
            ("Track", track.track.map(String.init) ?? "Unknown"),
            ("Disc", track.disc.map(String.init) ?? "Unknown"),
            (
              "Duration",
              track.durationSeconds.map {
                formatDuration($0)
              } ?? "Unknown"
            ),
          ]
        )
      }
    } label: {
      HStack {
        Label(file.name, systemImage: "doc")
          .lineLimit(1)

        Spacer()

        Text(byteCount(file.sizeBytes))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.55))
    .clipShape(.rect(cornerRadius: 12))
  }
}

private struct GameSaveDataInfoView: View {
  let item: GameSaveDataItem

  var body: some View {
    DisclosureGroup {
      GameInfoFields(
        fields: [
          ("ID", item.id.formatted()),
          ("File Name", item.fileName),
          ("Extension", item.fileExtension),
          ("Path", item.filePath),
          ("Full Path", item.fullPath),
          ("Size", byteCount(item.fileSizeBytes)),
          (
            "Availability",
            item.isMissingFromFileSystem
              ? "Missing from RomM filesystem"
              : "Available on RomM"
          ),
          (
            "Created",
            item.createdAt?.formatted(
              date: .abbreviated,
              time: .standard
            ) ?? "Unknown"
          ),
          (
            "Updated",
            item.updatedAt?.formatted(
              date: .abbreviated,
              time: .standard
            ) ?? "Unknown"
          ),
          ("Emulator", item.emulator ?? "Unknown"),
          ("Slot", item.slot ?? "Unknown"),
          ("Content Hash", item.contentHash ?? "Unknown"),
          ("Public", item.isPublic ? "Yes" : "No"),
          (
            "Download URL",
            item.downloadURL?.absoluteString ?? "Unavailable"
          ),
          (
            "Screenshot",
            item.screenshotURL?.absoluteString ?? "Unavailable"
          ),
        ]
      )
    } label: {
      HStack(spacing: 10) {
        Image(
          systemName:
            item.kind == .save
            ? "externaldrive.fill"
            : "clock.arrow.circlepath"
        )
        .foregroundStyle(
          item.kind == .save ? Color.blue : Color.purple
        )

        VStack(alignment: .leading, spacing: 2) {
          Text(item.fileName)
            .lineLimit(1)
          Text(
            [
              item.emulator,
              item.slot,
              byteCount(item.fileSizeBytes),
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Spacer()

        if item.isMissingFromFileSystem {
          Label("Missing", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .padding(.vertical, 5)
  }
}

private func byteCount(_ bytes: Int64) -> String {
  ByteCountFormatter.string(
    fromByteCount: bytes,
    countStyle: .file
  )
}

private func formatServerDate(_ value: String?) -> String? {
  guard
    let value,
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else {
    return nil
  }

  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [
    .withInternetDateTime,
    .withFractionalSeconds,
  ]
  let standardFormatter = ISO8601DateFormatter()
  guard
    let date =
      fractionalFormatter.date(from: value)
      ?? standardFormatter.date(from: value)
  else {
    return value
  }
  return date.formatted(date: .abbreviated, time: .standard)
}

private func formatDuration(_ seconds: Double) -> String {
  let roundedSeconds = max(0, Int(seconds.rounded()))
  return String(
    format: "%d:%02d",
    roundedSeconds / 60,
    roundedSeconds % 60
  )
}
