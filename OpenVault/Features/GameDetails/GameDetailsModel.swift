import Foundation
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

    init(
        game: GameSummary,
        session: ServerSession,
        service: any LibraryServing
    ) {
        self.game = game
        self.session = session
        self.service = service
    }

    func load() async {
        guard !hasLoaded else {
            return
        }
        await reload()
    }

    func reload() async {
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

    func prepareToPlay(_ game: GameDetails) async -> LibretroRunRequest? {
        guard !isPreparingToPlay, let playbackCore else {
            return nil
        }

        isPreparingToPlay = true
        playbackDownloadProgress = nil
        playbackErrorMessage = nil
        defer {
            isPreparingToPlay = false
            playbackDownloadProgress = nil
        }

        do {
            async let contentURL = service.prepareGameForPlay(
                game,
                in: session,
                supportedFileExtensions: playbackCore.fileExtensions,
                loadsArchivesDirectly: playbackCore.loadsArchivesDirectly == true,
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
                        }
                    }
                }
            )
            async let systemDirectory = service.prepareFirmwareForPlay(
                for: game.systemID,
                requirements: playbackCore.firmware,
                in: session
            )
            async let saveSync = service.prepareCartridgeSaveForPlay(
                game,
                in: session,
                emulator: "OpenVault",
                coreID: playbackCore.id
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
                systemDirectory: prepared.1,
                saveSync: prepared.2
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
        playbackCore = try? LibretroInstallation.bundled()
            .compatibleCore(
                systemName: details.systemName,
                fileExtension: details.fileExtension,
                archiveMemberNames: details.files.flatMap {
                    $0.archiveMembers.map(\.name)
                },
                contentFileNames: details.files
                    .filter { $0.isTopLevel }
                    .map(\.name)
            )
    }
}
