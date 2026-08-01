import Foundation
import OSLog
import Observation

enum GameDetailsDataSource: Equatable, Sendable {
    case remote
    case cachedDetails
    case librarySummary
}

@MainActor
@Observable
final class GameDetailsModel {
    let game: GameSummary
    let session: ServerSession
    let service: any LibraryServing

    private(set) var details: GameDetails?
    private(set) var dataSource: GameDetailsDataSource?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var refreshErrorMessage: String?
    private(set) var isDownloading = false
    private(set) var downloadProgress: RomMDownloadProgress?
    private(set) var isDownloaded = false
    private(set) var isLocallyAvailable = false
    private(set) var didDownloadGame = false
    private(set) var isRemovingDownload = false
    private(set) var didRemoveDownload = false
    private(set) var downloadErrorMessage: String?
    private(set) var isExporting = false
    private(set) var exportedFileURL: URL?
    private(set) var exportErrorMessage: String?
    private(set) var playbackCore: LibretroCoreManifest.Core?
    private(set) var isPreparingToPlay = false
    private(set) var playbackDownloadProgress: RomMDownloadProgress?
    private(set) var playbackErrorMessage: String?
    private(set) var isUpdatingUserMetadata = false
    private(set) var userMetadataErrorMessage: String?

    private var hasLoaded = false
    private let libretroInstallation: LibretroInstallation?

    init(
        game: GameSummary,
        session: ServerSession,
        service: any LibraryServing,
        libretroInstallation: LibretroInstallation? = try? .bundled()
    ) {
        self.game = game
        self.session = session
        self.service = service
        self.libretroInstallation = libretroInstallation
        playbackCore = libretroInstallation?.compatibleCore(
            systemName: game.systemName,
            fileExtension: "",
            includingExperimental:
                LibretroCorePreferences.enablesExperimentalCores()
        )
    }

    func load() async {
        guard !hasLoaded else {
            return
        }
        await reload(
            refreshesFromServer: true,
            stopsAfterFindingLocalGame: false
        )
    }

    func reload() async {
        await reload(
            refreshesFromServer: true,
            stopsAfterFindingLocalGame: false
        )
    }

    /// Loads only the metadata required to start playback.
    ///
    /// Already-downloaded games use cached metadata immediately. RomM remains
    /// the source of truth for non-local games, while save synchronization is
    /// handled separately during playback preparation.
    func loadForPlayback(allowsRemoteAccess: Bool) async {
        guard !hasLoaded else {
            return
        }
        await reload(
            refreshesFromServer: allowsRemoteAccess,
            stopsAfterFindingLocalGame: true
        )
    }

    private func reload(
        refreshesFromServer: Bool,
        stopsAfterFindingLocalGame: Bool
    ) async {
        isLoading = details == nil
        errorMessage = nil
        refreshErrorMessage = nil
        async let downloadedGameIDsRequest = service.downloadedGameIDs(in: session)
        async let managedDownloadedGameIDsRequest = service.managedDownloadedGameIDs(
            in: session
        )
        let (downloadedGameIDs, managedDownloadedGameIDs) = await (
            downloadedGameIDsRequest,
            managedDownloadedGameIDsRequest
        )
        isLocallyAvailable = downloadedGameIDs.contains(game.id)
        isDownloaded = managedDownloadedGameIDs.contains(game.id)

        do {
            if let cachedDetails = try await service.cachedGameDetails(
                for: game.id,
                in: session
            ) {
                apply(cachedDetails, source: .cachedDetails)
            } else if details == nil {
                apply(.cachedSummary(game), source: .librarySummary)
            }
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            if details == nil {
                apply(.cachedSummary(game), source: .librarySummary)
            }
            refreshErrorMessage = error.localizedDescription
        }

        if !refreshesFromServer
            || (stopsAfterFindingLocalGame && isLocallyAvailable)
        {
            hasLoaded = true
            isLoading = false
            return
        }

        do {
            let refreshedDetails = try await service.gameDetails(
                for: game.id,
                in: session
            )
            apply(refreshedDetails, source: .remote)
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            if details == nil {
                errorMessage = error.localizedDescription
            } else {
                refreshErrorMessage = error.localizedDescription
            }
        }

        hasLoaded = true
        isLoading = false
    }

    func download(_ game: GameDetails) async {
        guard !isDownloading else {
            return
        }

        isDownloading = true
        downloadProgress = nil
        didDownloadGame = false
        didRemoveDownload = false
        downloadErrorMessage = nil

        do {
            _ = try await service.downloadGame(
                game,
                in: session,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else {
                            return
                        }
                        if progress.bytesReceived
                            >= (self.downloadProgress?.bytesReceived ?? 0)
                        {
                            self.downloadProgress = progress
                        }
                    }
                }
            )
            isDownloaded = true
            isLocallyAvailable = true
            didDownloadGame = true
        } catch is CancellationError {
            // Cancellation is expected when the user leaves the details view.
        } catch {
            downloadErrorMessage = error.localizedDescription
        }

        isDownloading = false
        downloadProgress = nil
    }

    func removeDownload() async {
        guard !isRemovingDownload else {
            return
        }

        isRemovingDownload = true
        didDownloadGame = false
        didRemoveDownload = false
        downloadErrorMessage = nil

        do {
            try await service.removeDownloadedGame(
                withID: game.id,
                in: session
            )
            isDownloaded = false
            isLocallyAvailable = false
            didRemoveDownload = true
        } catch is CancellationError {
            // Cancellation is expected when the user leaves the details view.
        } catch {
            downloadErrorMessage = error.localizedDescription
        }

        isRemovingDownload = false
    }

    func dismissDownloadResult() {
        didDownloadGame = false
        didRemoveDownload = false
        downloadErrorMessage = nil
    }

    func export(_ game: GameDetails) async {
        guard !isExporting else {
            return
        }

        isExporting = true
        exportedFileURL = nil
        exportErrorMessage = nil

        do {
            exportedFileURL = try await service.exportGame(game, in: session)
        } catch is CancellationError {
            // Cancellation is expected when the user leaves the details view.
        } catch {
            exportErrorMessage = error.localizedDescription
        }

        isExporting = false
    }

    func dismissExportResult() {
        exportedFileURL = nil
        exportErrorMessage = nil
    }

    func prepareToPlay(
        _ game: GameDetails,
        synchronizesWithServer: Bool = true,
        onProgress: (@MainActor (RomMDownloadProgress?) -> Void)? = nil
    ) async -> LibretroRunRequest? {
        guard !isPreparingToPlay, let playbackCore else {
            return nil
        }

        isPreparingToPlay = true
        playbackDownloadProgress = nil
        playbackErrorMessage = nil
        onProgress?(nil)
        defer {
            isPreparingToPlay = false
            playbackDownloadProgress = nil
            onProgress?(nil)
        }

        do {
            async let contentURL = service.prepareGameForPlay(
                game,
                in: session,
                supportedFileExtensions: playbackCore.fileExtensions,
                loadsArchivesDirectly: playbackCore.loadsArchivesDirectly == true,
                allowsRemoteAccess: synchronizesWithServer,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingToPlay else {
                            return
                        }
                        if progress.bytesReceived
                            >= (
                                self.playbackDownloadProgress?
                                    .bytesReceived ?? 0
                            )
                        {
                            self.playbackDownloadProgress = progress
                            onProgress?(progress)
                        }
                    }
                }
            )
            async let systemDirectory = service.prepareFirmwareForPlay(
                for: game.systemID,
                requirements: playbackCore.firmware,
                in: session,
                allowsRemoteAccess: synchronizesWithServer
            )
            async let saveSync = service.prepareCartridgeSaveForPlay(
                game,
                in: session,
                emulator: "RetroVault",
                coreID: playbackCore.id,
                allowsRemoteAccess: synchronizesWithServer
            )
            let prepared = try await (
                contentURL,
                systemDirectory,
                saveSync
            )
            isDownloaded = true
            isLocallyAvailable = true
            return LibretroRunRequest(
                title: game.name,
                coreID: playbackCore.id,
                contentURL: prepared.0,
                systemName: game.systemName,
                systemDirectory: prepared.1,
                saveSync: prepared.2
            )
        } catch is CancellationError {
            // Not an error worth showing: something else asked for this work
            // to stop, usually a library refresh replacing the model.
            RetroVaultLog.libretro.info(
                "Playback preparation was cancelled before it finished"
            )
            return nil
        } catch {
            playbackErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Prepares a managed Vita archive for the optional Vita3K engine.
    ///
    /// Vita3K owns installation and firmware inside its private environment;
    /// RetroVault remains responsible for managed download and offline reuse.
    func prepareForVita3K(
        _ game: GameDetails,
        synchronizesWithServer: Bool = true,
        onProgress: (@MainActor (RomMDownloadProgress?) -> Void)? = nil
    ) async -> Vita3KRunRequest? {
        guard !isPreparingToPlay else {
            return nil
        }

        isPreparingToPlay = true
        playbackDownloadProgress = nil
        playbackErrorMessage = nil
        onProgress?(nil)
        defer {
            isPreparingToPlay = false
            playbackDownloadProgress = nil
            onProgress?(nil)
        }

        do {
            let firmwareResult: Result<[URL], Error>
            do {
                firmwareResult = .success(
                    try await service.prepareVitaFirmwareForPlay(
                        for: game.systemID,
                        in: session,
                        allowsRemoteAccess: synchronizesWithServer
                    )
                )
            } catch {
                // The engine may already have firmware installed. Preserve the
                // fetch error so the player can show it only when firmware is
                // actually missing.
                firmwareResult = .failure(error)
            }

            let archiveURL = try await service.prepareGameForPlay(
                game,
                in: session,
                // PKG installation also needs a zRIF work.bin key. Keep the
                // hosted preview honest until RomM can supply that alongside
                // the package.
                supportedFileExtensions: ["vpk", "zip"],
                loadsArchivesDirectly: true,
                allowsRemoteAccess: synchronizesWithServer,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreparingToPlay else {
                            return
                        }
                        if progress.bytesReceived
                            >= (self.playbackDownloadProgress?.bytesReceived ?? 0)
                        {
                            self.playbackDownloadProgress = progress
                            onProgress?(progress)
                        }
                    }
                }
            )
            isDownloaded = true
            isLocallyAvailable = true
            let firmwareURLs: [URL]
            let firmwarePreparationError: String?
            switch firmwareResult {
            case .success(let urls):
                firmwareURLs = urls
                firmwarePreparationError = nil
            case .failure(let error):
                firmwareURLs = []
                firmwarePreparationError = error.localizedDescription
            }
            return Vita3KRunRequest(
                gameID: game.id,
                title: game.name,
                archiveURL: archiveURL,
                firmwareURLs: firmwareURLs,
                firmwarePreparationError: firmwarePreparationError
            )
        } catch is CancellationError {
            return nil
        } catch {
            playbackErrorMessage = error.localizedDescription
            return nil
        }
    }

    func dismissPlaybackError() {
        playbackErrorMessage = nil
    }

    func updateUserMetadata(_ metadata: GameUserMetadata) async {
        guard !isUpdatingUserMetadata, let details else {
            return
        }

        let previousDetails = details
        var optimisticDetails = details
        optimisticDetails.userMetadata = metadata
        self.details = optimisticDetails
        isUpdatingUserMetadata = true
        userMetadataErrorMessage = nil

        do {
            self.details = try await service.updateUserMetadata(
                metadata,
                for: details,
                in: session
            )
        } catch is CancellationError {
            self.details = previousDetails
        } catch {
            self.details = previousDetails
            userMetadataErrorMessage = error.localizedDescription
        }

        isUpdatingUserMetadata = false
    }

    func dismissUserMetadataError() {
        userMetadataErrorMessage = nil
    }

    private func apply(
        _ details: GameDetails,
        source: GameDetailsDataSource
    ) {
        self.details = details
        dataSource = source
        // Read here rather than left to `compatibleCore`'s default, so the
        // core set this resolves against is the one in effect when the game
        // was opened.
        if let resolvedCore = libretroInstallation?.compatibleCore(
            systemName: details.systemName,
            fileExtension: details.fileExtension,
            archiveMemberNames: details.files.flatMap {
                $0.archiveMembers.map(\.name)
            },
            contentFileNames: details.files
                .filter { $0.isTopLevel }
                .map(\.name),
            includingExperimental:
                LibretroCorePreferences.enablesExperimentalCores()
        ) {
            playbackCore = resolvedCore
        }
    }
}
