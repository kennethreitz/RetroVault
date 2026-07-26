import AppKit
import SwiftUI

private enum GameDetailsTab: String, CaseIterable, Identifiable {
    case overview
    case files
    case media
    case saveData
    case metadata

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .files:
            "Files"
        case .media:
            "Media"
        case .saveData:
            "Save Data"
        case .metadata:
            "Metadata"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "rectangle.grid.1x2"
        case .files:
            "doc.on.doc"
        case .media:
            "photo.on.rectangle.angled"
        case .saveData:
            "externaldrive.badge.timemachine"
        case .metadata:
            "info.circle"
        }
    }
}

private enum GameSaveDataTab: String, CaseIterable, Identifiable {
    case saves
    case states

    var id: Self { self }

    var title: String {
        switch self {
        case .saves:
            "Saves"
        case .states:
            "States"
        }
    }
}

private enum GameMediaTab: String, CaseIterable, Identifiable {
    case manual
    case screenshots
    case soundtrack

    var id: Self { self }

    var title: String {
        switch self {
        case .manual:
            "Manual"
        case .screenshots:
            "Screenshots"
        case .soundtrack:
            "Soundtrack"
        }
    }
}

private enum RomMPlayStatus: String, CaseIterable, Identifiable {
    case incomplete
    case finished
    case completed100 = "completed_100"
    case retired
    case neverPlaying = "never_playing"

    var id: Self { self }

    var title: String {
        switch self {
        case .incomplete:
            "Incomplete"
        case .finished:
            "Finished"
        case .completed100:
            "Completed 100%"
        case .retired:
            "Retired"
        case .neverPlaying:
            "Never Playing"
        }
    }
}

struct GameDetailsViewport: Equatable {
    let origin: CGPoint
    let size: CGSize

    init(containerFrame: CGRect, safeAreaInsets: EdgeInsets) {
        let leadingInset = max(
            safeAreaInsets.leading - max(containerFrame.minX, 0),
            0
        )
        let topInset = max(
            safeAreaInsets.top - max(containerFrame.minY, 0),
            0
        )

        origin = CGPoint(
            x: leadingInset,
            y: topInset
        )
        size = CGSize(
            width: max(
                containerFrame.width
                    - leadingInset
                    - safeAreaInsets.trailing,
                0
            ),
            height: max(
                containerFrame.height
                    - topInset
                    - safeAreaInsets.bottom,
                0
            )
        )
    }
}

struct GameDetailsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var model: GameDetailsModel
    @State private var selectedTab = GameDetailsTab.overview
    @State private var selectedMediaTab = GameMediaTab.manual
    @State private var selectedSaveDataTab = GameSaveDataTab.saves

    init(
        game: GameSummary,
        session: ServerSession,
        service: any LibraryServing
    ) {
        _model = State(
            initialValue: GameDetailsModel(
                game: game,
                session: session,
                service: service
            )
        )
    }

    var body: some View {
        Group {
            if let details = model.details {
                detailsContent(details)
            } else if let errorMessage = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Load Game", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.reload()
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                ProgressView("Loading \(model.game.name)…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.details?.name ?? model.game.name)
        .task {
            await model.load()
        }
        .alert(
            downloadAlertTitle,
            isPresented: downloadAlertIsPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadAlertMessage)
        }
        .alert(
            exportAlertTitle,
            isPresented: exportAlertIsPresented
        ) {
            if let exportedFileURL = model.exportedFileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedFileURL])
                }
            }

            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .alert(
            "Couldn’t Start Game",
            isPresented: playbackAlertIsPresented
        ) {
            Button("OK", role: .cancel) {
                model.dismissPlaybackError()
            }
        } message: {
            Text(
                model.playbackErrorMessage
                    ?? "OpenVault could not prepare this game for playback."
            )
        }
        .alert(
            "Couldn’t Save Changes",
            isPresented: userMetadataAlertIsPresented
        ) {
            Button("OK", role: .cancel) {
                model.dismissUserMetadataError()
            }
        } message: {
            Text(
                model.userMetadataErrorMessage
                    ?? "OpenVault could not update this game in RomM."
            )
        }
    }

    private func detailsContent(_ details: GameDetails) -> some View {
        GeometryReader { geometry in
            let viewport = GameDetailsViewport(
                containerFrame: geometry.frame(in: .global),
                safeAreaInsets: geometry.safeAreaInsets
            )

            ZStack(alignment: .topLeading) {
                GameDetailsBackdrop(
                    details: details,
                    session: model.session,
                    service: model.service
                )

                Group {
                    if viewport.size.width >= 820 {
                        desktopLayout(
                            details,
                            viewportHeight: viewport.size.height
                        )
                    } else {
                        compactLayout(details)
                    }
                }
                .frame(
                    width: viewport.size.width,
                    height: viewport.size.height,
                    alignment: .topLeading
                )
                .clipped()
                .offset(
                    x: viewport.origin.x,
                    y: viewport.origin.y
                )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
        }
        .clipped()
    }

    private func desktopLayout(
        _ details: GameDetails,
        viewportHeight: CGFloat
    ) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 46) {
                coverColumn(details)
                    .padding(.top, 36)

                VStack(alignment: .leading, spacing: 0) {
                    gameHeader(details)
                        .padding(.top, 22)

                    GameDetailsTabBar(
                        selection: $selectedTab,
                        fileCount: details.files.count,
                        saveDataCount: details.saves.count + details.states.count
                    )
                    .padding(.top, 18)

                    Divider()
                        .padding(.top, 10)

                    tabContent(details)
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                        .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 34)
            .frame(maxWidth: 1_360, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(height: viewportHeight)
        .scrollIndicators(.visible)
    }

    private func compactLayout(_ details: GameDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                coverColumn(details)
                    .frame(maxWidth: .infinity)

                gameHeader(details)

                GameDetailsTabBar(
                    selection: $selectedTab,
                    fileCount: details.files.count,
                    saveDataCount: details.saves.count + details.states.count
                )

                Divider()

                tabContent(details)
                    .padding(.bottom, 28)
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private func coverColumn(_ details: GameDetails) -> some View {
        VStack(spacing: 14) {
            GameCoverView(
                game: details.gameSummary,
                session: model.session,
                service: model.service
            )
            .frame(width: 260)
            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)

            if let core = model.playbackCore {
                Button {
                    Task {
                        if let request = await model.prepareToPlay(details) {
                            openWindow(value: request)
                        }
                    }
                } label: {
                    Group {
                        if model.isPreparingToPlay {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Preparing…")
                            }
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(
                    model.isPreparingToPlay
                        || model.isDownloading
                        || model.isRemovingDownload
                        || model.isExporting
                        || details.isMissingFromFileSystem
                )
                .help("Play with the bundled \(core.displayName) core.")

                if model.isPreparingToPlay,
                    let progress = model.playbackDownloadProgress
                {
                    RomMDownloadProgressView(
                        progress: progress,
                        title: "Downloading from RomM"
                    )
                }
            }

            if details.isMissingFromFileSystem {
                DetailBadge(
                    "Missing from Filesystem",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
            }
        }
        .frame(width: 260)
    }

    private func gameHeader(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(details.name)
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .tracking(-0.7)
                .textSelection(.enabled)

            FlowLayout(spacing: 9) {
                Label(details.systemName, systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)

                if let cachedDetailsLabel {
                    Label(cachedDetailsLabel, systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                        .help(
                            model.refreshErrorMessage
                                ?? "Showing metadata stored on this Mac."
                        )
                }

                if let releaseDate = details.metadata.firstReleaseDate {
                    Text(releaseDate.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }

                if details.crcHash != nil {
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("RomM returned a CRC hash for this game.")
                } else if details.isIdentified {
                    Label("Identified", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }

                Button {
                    Task {
                        if model.isLocallyAvailable {
                            await model.removeDownload()
                        } else {
                            await model.download(details)
                        }
                    }
                } label: {
                    if model.isDownloading {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Downloading…")
                        }
                    } else if model.isRemovingDownload {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Removing…")
                        }
                    } else {
                        Label(
                            model.isLocallyAvailable ? "Remove Download" : "Download",
                            systemImage: model.isLocallyAvailable
                                ? "trash"
                                : "arrow.down.circle"
                        )
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(
                    model.isDownloading
                        || model.isRemovingDownload
                        || (details.isMissingFromFileSystem && !model.isLocallyAvailable)
                )
                .help(
                    model.isLocallyAvailable
                        ? "Remove OpenVault’s local copy. The game remains on RomM."
                        : details.isMissingFromFileSystem
                        ? "RomM reports that this game is missing from the server filesystem."
                        : "Add this game to OpenVault’s managed local library."
                )

                Button {
                    Task {
                        await model.export(details)
                    }
                } label: {
                    if model.isExporting {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(
                    model.isExporting
                        || model.isDownloading
                        || model.isRemovingDownload
                        || (details.isMissingFromFileSystem && !model.isLocallyAvailable)
                )
                .help("Export a shareable copy to your Downloads folder.")

                SaveDataCountButton(
                    title: countLabel(details.saves.count, singular: "Save"),
                    systemImage: "externaldrive.fill",
                    tint: details.saves.isEmpty ? .secondary : .blue
                ) {
                    showSaveData(.saves)
                }
                .help("Show save files available for your RomM user.")

                SaveDataCountButton(
                    title: countLabel(details.states.count, singular: "State"),
                    systemImage: "clock.arrow.circlepath",
                    tint: details.states.isEmpty ? .secondary : .purple
                ) {
                    showSaveData(.states)
                }
                .help("Show save states available for your RomM user.")
            }
            .font(.callout)

            if model.isDownloading, let progress = model.downloadProgress {
                RomMDownloadProgressView(
                    progress: progress,
                    title: "Adding to Downloaded"
                )
                .frame(maxWidth: 420)
            }

            if !details.regions.isEmpty || !details.languages.isEmpty || !details.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(details.regions, id: \.self) {
                        RomMTag($0, tint: .blue)
                    }
                    ForEach(details.languages, id: \.self) {
                        RomMTag($0, tint: .purple)
                    }
                    ForEach(details.tags, id: \.self) {
                        RomMTag($0)
                    }
                }
            }

            GlassEffectContainer(spacing: 8) {
                activityRibbon(details)
            }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityRibbon(_ details: GameDetails) -> some View {
        FlowLayout(spacing: 8) {
            EditableStatusPill(
                status: details.userMetadata.status,
                isDisabled: model.isUpdatingUserMetadata
            ) { status in
                updateUserMetadata(for: details) {
                    $0.status = status
                }
            }

            EditableFlagPill(
                title: "Now Playing",
                systemImage: "play.circle.fill",
                tint: .green,
                isOn: details.userMetadata.isNowPlaying,
                isDisabled: model.isUpdatingUserMetadata
            ) {
                updateUserMetadata(for: details) {
                    $0.isNowPlaying.toggle()
                }
            }

            EditableFlagPill(
                title: "Backlogged",
                systemImage: "text.badge.plus",
                tint: .orange,
                isOn: details.userMetadata.isBacklogged,
                isDisabled: model.isUpdatingUserMetadata
            ) {
                updateUserMetadata(for: details) {
                    $0.isBacklogged.toggle()
                }
            }

            EditableFlagPill(
                title: "Hidden",
                systemImage: "eye.slash.fill",
                tint: .secondary,
                isOn: details.userMetadata.isHidden,
                isDisabled: model.isUpdatingUserMetadata
            ) {
                updateUserMetadata(for: details) {
                    $0.isHidden.toggle()
                }
            }

            EditableGameMetricPill(
                title: "Completion",
                value: details.userMetadata.completion,
                range: 0 ... 100,
                suffix: "%",
                systemImage: "chart.bar.fill",
                tint: .blue,
                isDisabled: model.isUpdatingUserMetadata
            ) { value in
                updateUserMetadata(for: details) {
                    $0.completion = value
                }
            }

            EditableGameMetricPill(
                title: "Rating",
                value: details.userMetadata.rating,
                range: 0 ... 10,
                suffix: "",
                systemImage: "star.fill",
                tint: .yellow,
                isDisabled: model.isUpdatingUserMetadata
            ) { value in
                updateUserMetadata(for: details) {
                    $0.rating = value
                }
            }

            EditableGameMetricPill(
                title: "Difficulty",
                value: details.userMetadata.difficulty,
                range: 0 ... 10,
                suffix: "",
                systemImage: "flame.fill",
                tint: .red,
                isDisabled: model.isUpdatingUserMetadata
            ) { value in
                updateUserMetadata(for: details) {
                    $0.difficulty = value
                }
            }

            if model.isUpdatingUserMetadata {
                ProgressView()
                    .controlSize(.small)
                    .help("Saving to RomM")
            }

            Link(destination: model.session.serverURL.endpoint("rom/\(details.id)")) {
                Label("Open in RomM", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private func updateUserMetadata(
        for details: GameDetails,
        mutation: (inout GameUserMetadata) -> Void
    ) {
        var metadata = details.userMetadata
        mutation(&metadata)

        Task {
            await model.updateUserMetadata(metadata)
        }
    }

    private var cachedDetailsLabel: String? {
        switch model.dataSource {
        case .cachedDetails:
            "Cached"
        case .librarySummary:
            "Cached Summary"
        case .remote, .none:
            nil
        }
    }

    private var downloadAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                model.didDownloadGame
                    || model.didRemoveDownload
                    || model.downloadErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    model.dismissDownloadResult()
                }
            }
        )
    }

    private var exportAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                model.exportedFileURL != nil || model.exportErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    model.dismissExportResult()
                }
            }
        )
    }

    private var playbackAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                model.playbackErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    model.dismissPlaybackError()
                }
            }
        )
    }

    private var userMetadataAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                model.userMetadataErrorMessage != nil
            },
            set: { isPresented in
                if !isPresented {
                    model.dismissUserMetadataError()
                }
            }
        )
    }

    private var downloadAlertTitle: String {
        if model.didDownloadGame {
            return "Download Complete"
        }
        if model.didRemoveDownload {
            return "Download Removed"
        }
        return "Download Failed"
    }

    private var downloadAlertMessage: String {
        if model.didDownloadGame {
            return "This game was added to OpenVault’s local library."
        }
        if model.didRemoveDownload {
            return "The local ROM was removed. The game remains available on RomM."
        }
        return model.downloadErrorMessage ?? "OpenVault could not download this game."
    }

    private var exportAlertTitle: String {
        model.exportedFileURL == nil ? "Export Failed" : "Export Complete"
    }

    private var exportAlertMessage: String {
        if let exportedFileURL = model.exportedFileURL {
            return "\(exportedFileURL.lastPathComponent) was saved to Downloads."
        }
        return model.exportErrorMessage ?? "OpenVault could not export this game."
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : "\(singular)s")"
    }

    private func showSaveData(_ tab: GameSaveDataTab) {
        selectedSaveDataTab = tab
        selectedTab = .saveData
    }

    @ViewBuilder
    private func tabContent(_ details: GameDetails) -> some View {
        switch selectedTab {
        case .overview:
            overviewTab(details)
        case .files:
            filesTab(details)
        case .media:
            mediaTab(details)
        case .saveData:
            saveDataTab(details)
        case .metadata:
            metadataTab(details)
        }
    }

    private func overviewTab(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if let summary = details.summary?.nilIfEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 820, alignment: .leading)
            } else {
                Text("No description is available from RomM.")
                    .foregroundStyle(.tertiary)
            }

            overviewFacts(details)

            infoGrid(details)

            DetailsSection(title: "Library Content", systemImage: "square.stack.3d.up") {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ContentStat(title: "Files", value: details.files.count, systemImage: "doc")
                    Button {
                        showSaveData(.saves)
                    } label: {
                        ContentStat(
                            title: "Saves",
                            value: details.saves.count,
                            systemImage: "externaldrive"
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Show saves")

                    Button {
                        showSaveData(.states)
                    } label: {
                        ContentStat(
                            title: "States",
                            value: details.states.count,
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Show save states")
                    ContentStat(
                        title: "Notes",
                        value: details.contentCounts.notes,
                        systemImage: "note.text"
                    )
                    ContentStat(
                        title: "Screenshots",
                        value: details.contentCounts.screenshots,
                        systemImage: "camera"
                    )
                    ContentStat(
                        title: "Collections",
                        value: details.contentCounts.collections,
                        systemImage: "square.stack"
                    )
                }
            }

            if !details.screenshotURLs.isEmpty {
                DetailsSection(title: "Screenshots", systemImage: "photo.on.rectangle.angled") {
                    screenshotStrip(details)
                }
            }

            if !details.providerIdentifiers.isEmpty {
                Text(
                    "Data provided by "
                        + details.providerIdentifiers.map(\.name).joined(separator: ", ")
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func overviewFacts(_ details: GameDetails) -> some View {
        let hasFacts = details.revision?.nilIfEmpty != nil
            || details.userMetadata.lastPlayed?.nilIfEmpty != nil
            || details.metadata.playerCount?.nilIfEmpty != nil
            || !details.metadata.ageRatings.isEmpty

        if hasFacts {
            VStack(alignment: .leading, spacing: 14) {
                if let revision = details.revision?.nilIfEmpty {
                    FactRow(label: "Revision") {
                        Text(revision)
                    }
                }

                if let lastPlayed = formatRomMDate(details.userMetadata.lastPlayed) {
                    FactRow(label: "Last Played") {
                        Text(lastPlayed)
                    }
                }

                if let playerCount = details.metadata.playerCount?.nilIfEmpty {
                    FactRow(label: "Players") {
                        RomMTag(playerCount, systemImage: "person.2.fill", tint: .blue)
                    }
                }

                if !details.metadata.ageRatings.isEmpty {
                    FactRow(label: "Age Rating") {
                        FlowLayout(spacing: 6) {
                            ForEach(details.metadata.ageRatings, id: \.self) {
                                RomMTag($0, tint: .orange)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func infoGrid(_ details: GameDetails) -> some View {
        let groups = [
            InfoGroup(title: "Genres", values: details.metadata.genres),
            InfoGroup(title: "Companies", values: details.metadata.companies),
            InfoGroup(title: "Franchises", values: details.metadata.franchises),
            InfoGroup(title: "Collections", values: details.metadata.collections),
            InfoGroup(title: "Game Modes", values: details.metadata.gameModes),
        ].filter { !$0.values.isEmpty }

        if !groups.isEmpty {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(groups) { group in
                    InfoGroupCard(group: group)
                }
            }
        }
    }

    private func screenshotStrip(_ details: GameDetails) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(details.screenshotURLs, id: \.absoluteString) { url in
                    RomMImageView(
                        url: url,
                        session: model.session,
                        service: model.service,
                        targetSize: CGSize(width: 680, height: 440),
                        contentMode: .fit,
                        placeholderSystemImage: "photo",
                        cornerRadius: 9,
                        imagePadding: 0
                    )
                    .frame(width: 340, height: 220)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private func filesTab(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            FileSummaryCard(details: details)

            if details.files.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("RomM did not return any files for this game.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ForEach(details.files) { file in
                    FileDetailsView(file: file)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediaTab(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Media", selection: $selectedMediaTab) {
                ForEach(GameMediaTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)

            switch selectedMediaTab {
            case .manual:
                manualPanel(details)
            case .screenshots:
                screenshotsPanel(details)
            case .soundtrack:
                soundtrackPanel(details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func manualPanel(_ details: GameDetails) -> some View {
        if let manualURL = details.manualURL {
            VStack(alignment: .leading, spacing: 14) {
                Label("Manual available", systemImage: "book.closed.fill")
                    .font(.title3.weight(.semibold))

                Text("Open the manual supplied by RomM in your default viewer.")
                    .foregroundStyle(.secondary)

                Link(destination: manualURL) {
                    Label("Open Manual", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glassProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        } else {
            ContentUnavailableView(
                "No Manual",
                systemImage: "book.closed",
                description: Text("RomM does not have a manual for this game.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    @ViewBuilder
    private func screenshotsPanel(_ details: GameDetails) -> some View {
        if details.screenshotURLs.isEmpty {
            ContentUnavailableView(
                "No Screenshots",
                systemImage: "photo.on.rectangle",
                description: Text("RomM does not have screenshots for this game.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16),
                ],
                spacing: 16
            ) {
                ForEach(details.screenshotURLs, id: \.absoluteString) { url in
                    RomMImageView(
                        url: url,
                        session: model.session,
                        service: model.service,
                        targetSize: CGSize(width: 840, height: 472),
                        contentMode: .fill,
                        placeholderSystemImage: "photo",
                        cornerRadius: 9,
                        imagePadding: 0
                    )
                    .aspectRatio(16 / 9, contentMode: .fit)
                }
            }
        }
    }

    @ViewBuilder
    private func soundtrackPanel(_ details: GameDetails) -> some View {
        let tracks = details.files.filter {
            $0.trackMetadata != nil || $0.category?.lowercased() == "soundtrack"
        }

        if tracks.isEmpty {
            ContentUnavailableView(
                "No Soundtrack",
                systemImage: "music.note.list",
                description: Text("RomM does not have soundtrack files for this game.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(tracks) { track in
                    FileDetailsView(file: track)
                }
            }
        }
    }

    private func saveDataTab(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Save Data", selection: $selectedSaveDataTab) {
                ForEach(GameSaveDataTab.allCases) { tab in
                    Text("\(tab.title) \(saveDataCount(for: tab, in: details))")
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            switch selectedSaveDataTab {
            case .saves:
                saveDataPanel(
                    items: details.saves,
                    emptyTitle: "No Saves",
                    emptyDescription: "RomM does not have save files for this game.",
                    emptySystemImage: "externaldrive.badge.xmark"
                )
            case .states:
                saveDataPanel(
                    items: details.states,
                    emptyTitle: "No States",
                    emptyDescription: "RomM does not have save states for this game.",
                    emptySystemImage: "clock.badge.xmark"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func saveDataPanel(
        items: [GameSaveDataItem],
        emptyTitle: String,
        emptyDescription: String,
        emptySystemImage: String
    ) -> some View {
        if items.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptySystemImage,
                description: Text(emptyDescription)
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    GameSaveDataRow(
                        item: item,
                        session: model.session,
                        service: model.service
                    )
                }
            }
        }
    }

    private func saveDataCount(for tab: GameSaveDataTab, in details: GameDetails) -> Int {
        switch tab {
        case .saves:
            details.saves.count
        case .states:
            details.states.count
        }
    }

    private func metadataTab(_ details: GameDetails) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            DetailsSection(title: "File Information", systemImage: "doc.text") {
                MetadataTable(
                    fields: [
                        DetailField(label: "File Name", value: details.fileName),
                        DetailField(label: "Size", value: formatBytes(details.fileSizeBytes)),
                        DetailField(
                            label: "Extension",
                            value: details.fileExtension.nilIfEmpty ?? "Not available"
                        ),
                    ]
                )
            }

            DetailsSection(title: "Hashes", systemImage: "number") {
                FlowLayout(spacing: 8) {
                    HashPill(label: "CRC", value: details.crcHash)
                    HashPill(label: "MD5", value: details.md5Hash)
                    HashPill(label: "SHA-1", value: details.sha1Hash)
                    HashPill(label: "RA", value: details.retroAchievementsHash)
                }
            }

            DetailsSection(title: "Verification", systemImage: "checkmark.seal") {
                FlowLayout(spacing: 8) {
                    RomMTag(
                        details.isIdentified ? "Identified" : "Unidentified",
                        systemImage: details.isIdentified
                            ? "checkmark.circle.fill"
                            : "xmark.circle",
                        tint: details.isIdentified ? .green : .secondary
                    )
                    RomMTag(
                        details.crcHash == nil ? "CRC unmatched" : "CRC matched",
                        systemImage: details.crcHash == nil
                            ? "xmark.circle"
                            : "checkmark.circle.fill",
                        tint: details.crcHash == nil ? .secondary : .green
                    )
                    RomMTag(
                        details.retroAchievementsHash == nil
                            ? "RetroAchievements unmatched"
                            : "RetroAchievements matched",
                        systemImage: details.retroAchievementsHash == nil
                            ? "xmark.circle"
                            : "checkmark.circle.fill",
                        tint: details.retroAchievementsHash == nil ? .secondary : .green
                    )
                }
            }

            if !details.providerIdentifiers.isEmpty {
                DetailsSection(title: "Metadata Sources", systemImage: "network") {
                    MetadataTable(
                        fields: details.providerIdentifiers.map {
                            DetailField(label: $0.name, value: $0.value)
                        }
                    )
                }
            }

            DetailsSection(title: "Game Metadata", systemImage: "list.bullet.rectangle") {
                MetadataTable(fields: descriptiveMetadataFields(details))
            }

            DetailsSection(title: "Technical Details", systemImage: "wrench.and.screwdriver") {
                MetadataTable(fields: technicalFields(details))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func descriptiveMetadataFields(_ details: GameDetails) -> [DetailField] {
        var fields: [DetailField] = []
        fields.appendIfPresent(
            "Release Date",
            details.metadata.firstReleaseDate?.formatted(date: .long, time: .omitted)
        )
        fields.appendIfPresent(
            "Average Rating",
            details.metadata.averageRating.map { String(format: "%.1f", $0) }
        )
        fields.appendIfPresent("Players", details.metadata.playerCount)
        fields.appendIfNotEmpty("Genres", details.metadata.genres)
        fields.appendIfNotEmpty("Game Modes", details.metadata.gameModes)
        fields.appendIfNotEmpty("Companies", details.metadata.companies)
        fields.appendIfNotEmpty("Franchises", details.metadata.franchises)
        fields.appendIfNotEmpty("Collections", details.metadata.collections)
        fields.appendIfNotEmpty("Age Ratings", details.metadata.ageRatings)
        fields.appendIfNotEmpty("Regions", details.regions)
        fields.appendIfNotEmpty("Languages", details.languages)
        fields.appendIfNotEmpty("Alternative Names", details.alternativeNames)
        fields.appendIfNotEmpty("Tags", details.tags)

        if fields.isEmpty {
            fields.append(DetailField(label: "Metadata", value: "No matched metadata"))
        }
        return fields
    }

    private func technicalFields(_ details: GameDetails) -> [DetailField] {
        var fields = [
            DetailField(label: "RomM ID", value: details.id.formatted()),
            DetailField(label: "System", value: details.systemName),
            DetailField(label: "Identified", value: yesNo(details.isIdentified)),
            DetailField(
                label: "Missing from Filesystem",
                value: yesNo(details.isMissingFromFileSystem)
            ),
            DetailField(label: "Created", value: displayDate(details.createdAt)),
            DetailField(label: "Updated", value: displayDate(details.updatedAt)),
        ]
        fields.appendIfPresent("Revision", details.revision)
        fields.appendIfPresent("Directory", details.filePath.nilIfEmpty)
        fields.appendIfPresent("Full Path", details.fullPath.nilIfEmpty)
        return fields
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func displayStatus(_ value: String?) -> String {
        guard let value = value?.nilIfEmpty else {
            return "Not set"
        }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func displayDate(_ value: String?) -> String {
        formatRomMDate(value) ?? "Never"
    }
}

private struct RomMDownloadProgressView: View {
    let progress: RomMDownloadProgress
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(byteDescription)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)

            Group {
                if let fractionCompleted = progress.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
        }
        .accessibilityElement(children: .combine)
    }

    private var byteDescription: String {
        let received = progress.bytesReceived.formatted(
            .byteCount(style: .file)
        )
        guard let totalBytesExpected = progress.totalBytesExpected else {
            return received
        }
        return "\(received) of \(totalBytesExpected.formatted(.byteCount(style: .file)))"
    }
}

private struct GameDetailsBackdrop: View {
    let details: GameDetails
    let session: ServerSession
    let service: any LibraryServing

    var body: some View {
        ZStack {
            RomMImageView(
                url: details.coverURL,
                session: session,
                service: service,
                targetSize: CGSize(width: 1_600, height: 1_000),
                contentMode: .fill,
                placeholderSystemImage: "gamecontroller",
                cornerRadius: 0,
                imagePadding: 0
            )
            .blur(radius: 52)
            .scaleEffect(1.2)
            .opacity(details.coverURL == nil ? 0 : 0.19)

            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    Color(nsColor: .windowBackgroundColor).opacity(0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GameDetailsTabBar: View {
    @Binding var selection: GameDetailsTab
    let fileCount: Int
    let saveDataCount: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(GameDetailsTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.systemImage)
                            Text(tab.title)

                            if let badge = badge(for: tab) {
                                Text(badge.formatted())
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        .font(.callout.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selection == tab ? Color.accentColor.opacity(0.13) : .clear,
                            in: .rect(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func badge(for tab: GameDetailsTab) -> Int? {
        switch tab {
        case .files:
            fileCount
        case .saveData:
            saveDataCount
        default:
            nil
        }
    }
}

private struct SaveDataCountButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .openVaultGlass(
                    tint: tint.opacity(0.14),
                    interactive: true,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
    }
}

private struct DetailBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

private struct EditableStatusPill: View {
    let status: String?
    let isDisabled: Bool
    let onChange: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                onChange(nil)
            } label: {
                if status?.nilIfEmpty == nil {
                    Label("Not Set", systemImage: "checkmark")
                } else {
                    Text("Not Set")
                }
            }

            Divider()

            ForEach(RomMPlayStatus.allCases) { option in
                Button {
                    onChange(option.rawValue)
                } label: {
                    if status == option.rawValue {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.blue)

                Text("Status")
                    .foregroundStyle(.secondary)

                Text(displayTitle)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .openVaultGlass(interactive: true, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isDisabled)
        .help("Change play status")
    }

    private var displayTitle: String {
        guard let status = status?.nilIfEmpty else {
            return "—"
        }
        return RomMPlayStatus(rawValue: status)?.title
            ?? status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct EditableFlagPill: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isOn: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(isOn ? .semibold : .regular)
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption)
            .foregroundStyle(isOn ? tint : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .openVaultGlass(
                tint: isOn ? tint.opacity(0.18) : nil,
                interactive: true,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isOn ? "Remove \(title)" : "Mark as \(title)")
    }
}

private struct EditableGameMetricPill: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let suffix: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let onSave: (Int) -> Void

    @State private var isEditing = false
    @State private var draftValue = 0

    var body: some View {
        Button {
            draftValue = value
            isEditing = true
        } label: {
            GameMetricPill(
                title: title,
                value: value > 0 ? formatted(value) : "—",
                systemImage: systemImage,
                tint: tint
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Edit \(title.lowercased())")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                        .foregroundStyle(tint)

                    Spacer()

                    Text(formatted(draftValue))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { Double(draftValue) },
                        set: { draftValue = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound) ... Double(range.upperBound),
                    step: 1
                )

                Stepper(
                    "\(formatted(draftValue)) of \(formatted(range.upperBound))",
                    value: $draftValue,
                    in: range
                )
                .monospacedDigit()

                HStack {
                    Button("Reset") {
                        isEditing = false
                        onSave(range.lowerBound)
                    }

                    Spacer()

                    Button("Cancel", role: .cancel) {
                        isEditing = false
                    }

                    Button("Save") {
                        isEditing = false
                        onSave(draftValue)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 300)
        }
    }

    private func formatted(_ value: Int) -> String {
        "\(value.formatted())\(suffix)"
    }
}

private struct GameMetricPill: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(title)
                .foregroundStyle(.secondary)

            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .openVaultGlass(
            tint: tint.opacity(0.10),
            interactive: true,
            in: Capsule()
        )
    }
}

private struct RomMTag: View {
    let title: String
    let systemImage: String?
    let tint: Color

    init(_ title: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.11), in: .capsule)
    }
}

private struct FactRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    init(label: String, @ViewBuilder content: () -> Content) {
        self.init(label, content: content)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .frame(width: 112, alignment: .leading)

            content
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InfoGroup: Identifiable {
    var id: String { title }

    let title: String
    let values: [String]
}

private struct InfoGroupCard: View {
    let group: InfoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)

            FlowLayout(spacing: 6) {
                ForEach(group.values, id: \.self) {
                    RomMTag($0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        }
    }
}

private struct ContentStat: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)

            Text(value.formatted())
                .font(.title3.weight(.semibold))
                .monospacedDigit()

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.separator.opacity(0.25), lineWidth: 0.5)
        }
    }
}

private struct GameSaveDataRow: View {
    let item: GameSaveDataItem
    let session: ServerSession
    let service: any LibraryServing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            preview

            VStack(alignment: .leading, spacing: 7) {
                Text(item.fileName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                FlowLayout(spacing: 6) {
                    if let emulator = item.emulator?.nilIfEmpty {
                        RomMTag(emulator, systemImage: "gamecontroller", tint: .orange)
                    }

                    if let slot = item.slot?.nilIfEmpty {
                        RomMTag(slot, systemImage: "rectangle.stack", tint: .blue)
                    }

                    if !item.fileExtension.isEmpty {
                        RomMTag(item.fileExtension.uppercased())
                    }

                    RomMTag(formatBytes(item.fileSizeBytes), systemImage: "internaldrive")

                    if item.isPublic {
                        RomMTag("Public", systemImage: "person.2.fill", tint: .green)
                    }

                    if item.isMissingFromFileSystem {
                        RomMTag(
                            "Missing",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                    }
                }

                if !item.filePath.isEmpty {
                    Text(item.filePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            if let updatedAt = item.updatedAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        }
        .help(item.fullPath)
    }

    @ViewBuilder
    private var preview: some View {
        if item.kind == .state, item.screenshotURL != nil {
            RomMImageView(
                url: item.screenshotURL,
                session: session,
                service: service,
                targetSize: CGSize(width: 320, height: 180),
                contentMode: .fill,
                placeholderSystemImage: "photo",
                cornerRadius: 7,
                imagePadding: 0
            )
            .frame(width: 92, height: 52)
        } else {
            Image(
                systemName: item.kind == .save
                    ? "externaldrive.fill"
                    : "clock.arrow.circlepath"
            )
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(item.kind == .save ? Color.blue : Color.purple)
            .frame(width: 52, height: 52)
            .background(.quaternary, in: .rect(cornerRadius: 7))
        }
    }
}

private struct DetailsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Spacer()

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct FileSummaryCard: View {
    let details: GameDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Label(details.fileName, systemImage: "folder")
                    .font(.headline)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer()

                if details.isMissingFromFileSystem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("Missing from filesystem")
                }
            }

            FlowLayout(spacing: 7) {
                Text("\(details.files.count.formatted()) files")
                Text(formatBytes(details.fileSizeBytes))

                if let revision = details.revision?.nilIfEmpty {
                    Text("Rev. \(revision)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                if let sha1Hash = details.sha1Hash?.nilIfEmpty {
                    HashPill(label: "SHA-1", value: sha1Hash)
                }
                if let md5Hash = details.md5Hash?.nilIfEmpty {
                    HashPill(label: "MD5", value: md5Hash)
                }
                if let crcHash = details.crcHash?.nilIfEmpty {
                    HashPill(label: "CRC", value: crcHash)
                }
                if let retroAchievementsHash = details.retroAchievementsHash?.nilIfEmpty {
                    HashPill(label: "RA", value: retroAchievementsHash)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
    }
}

private struct HashPill: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .fontWeight(.bold)
                .foregroundStyle(.tertiary)

            Text(value?.nilIfEmpty ?? "—")
                .lineLimit(1)
        }
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .capsule)
    }
}

private struct MetadataTable: View {
    let fields: [DetailField]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 11) {
            ForEach(fields) { field in
                GridRow(alignment: .firstTextBaseline) {
                    Text(field.label)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)

                    Text(field.value)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FileDetailsView: View {
    let file: GameFile
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: categorySystemImage)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text(file.name)
                        .font(.callout.weight(.medium))
                        .monospaced()
                        .lineLimit(1)
                        .textSelection(.enabled)

                    FlowLayout(spacing: 6) {
                        if let category = file.category?.nilIfEmpty {
                            RomMTag(category.capitalized, tint: .blue)
                        }

                        Text(formatBytes(file.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        if let track = file.trackMetadata,
                           let duration = track.durationSeconds
                        {
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Button {
                    showsDetails.toggle()
                } label: {
                    Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsDetails ? "Hide file details" : "Show file details")
            }

            FlowLayout(spacing: 5) {
                if let sha1Hash = file.sha1Hash?.nilIfEmpty {
                    HashPill(label: "SHA-1", value: sha1Hash)
                }
                if let chdSHA1Hash = file.chdSHA1Hash?.nilIfEmpty {
                    HashPill(label: "CHD SHA-1", value: chdSHA1Hash)
                }
                if let md5Hash = file.md5Hash?.nilIfEmpty {
                    HashPill(label: "MD5", value: md5Hash)
                }
                if let crcHash = file.crcHash?.nilIfEmpty {
                    HashPill(label: "CRC", value: crcHash)
                }
                if let retroAchievementsHash = file.retroAchievementsHash?.nilIfEmpty {
                    HashPill(label: "RA", value: retroAchievementsHash)
                }
            }

            if let track = file.trackMetadata {
                let summary = [track.title, track.artist, track.album]
                    .compactMap { $0?.nilIfEmpty }
                    .joined(separator: " · ")

                if !summary.isEmpty {
                    Label(summary, systemImage: "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsDetails {
                Divider()

                MetadataTable(fields: fields)

                if !file.archiveMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Archive Members")
                            .font(.subheadline.weight(.semibold))

                        ForEach(file.archiveMembers) { member in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(member.name)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)

                                FlowLayout(spacing: 5) {
                                    Text(formatBytes(member.sizeBytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HashPill(label: "CRC", value: member.crcHash)
                                    HashPill(label: "MD5", value: member.md5Hash)
                                    HashPill(label: "SHA-1", value: member.sha1Hash)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        }
    }

    private var categorySystemImage: String {
        switch file.category?.lowercased() {
        case "game":
            "gamecontroller"
        case "dlc":
            "puzzlepiece"
        case "update":
            "arrow.triangle.2.circlepath"
        case "patch":
            "bandage"
        case "manual":
            "book.closed"
        case "soundtrack":
            "music.note"
        case "screenshot":
            "photo"
        default:
            "doc"
        }
    }

    private var fields: [DetailField] {
        var fields = [
            DetailField(label: "Top Level", value: file.isTopLevel ? "Yes" : "No"),
        ]
        fields.appendIfPresent("Path", file.path.nilIfEmpty)
        fields.appendIfPresent("Full Path", file.fullPath.nilIfEmpty)
        fields.appendIfPresent("Created", formatRomMDate(file.createdAt))
        fields.appendIfPresent("Updated", formatRomMDate(file.updatedAt))
        fields.appendIfPresent("Last Modified", formatRomMDate(file.lastModified))
        return fields
    }
}

private struct DetailField: Identifiable {
    var id: String {
        label
    }

    let label: String
    let value: String
}

private extension Array where Element == DetailField {
    mutating func appendIfPresent(_ label: String, _ value: String?) {
        if let value = value?.nilIfEmpty {
            append(DetailField(label: label, value: value))
        }
    }

    mutating func appendIfNotEmpty(_ label: String, _ values: [String]) {
        let values = values.compactMap(\.nilIfEmpty)
        guard !values.isEmpty else {
            return
        }
        append(DetailField(label: label, value: values.joined(separator: ", ")))
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? 10_000
        var rowWidth: CGFloat = 0
        var maximumRowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if rowWidth > 0, rowWidth + spacing + size.width > availableWidth {
                maximumRowWidth = max(maximumRowWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }

            if rowWidth > 0 {
                rowWidth += spacing
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }

        maximumRowWidth = max(maximumRowWidth, rowWidth)
        totalHeight += rowHeight

        return CGSize(
            width: proposal.width ?? maximumRowWidth,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func formatRomMDate(_ value: String?) -> String? {
    guard let value = value?.nilIfEmpty else {
        return nil
    }

    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains("."))
    guard let date = try? style.parse(value) else {
        return value
    }
    return date.formatted(date: .abbreviated, time: .shortened)
}
