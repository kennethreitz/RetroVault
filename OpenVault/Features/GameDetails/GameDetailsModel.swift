import Foundation
import Observation

@MainActor
@Observable
final class GameDetailsModel {
    let game: GameSummary
    let session: ServerSession
    let service: any LibraryServing

    private(set) var details: GameDetails?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isDownloading = false
    private(set) var downloadedFileURL: URL?
    private(set) var downloadErrorMessage: String?
    private(set) var playbackCore: LibretroCoreManifest.Core?
    private(set) var isPreparingToPlay = false
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
        isLoading = true
        errorMessage = nil

        do {
            let details = try await service.gameDetails(for: game.id, in: session)
            self.details = details
            playbackCore = try? LibretroInstallation.bundled()
                .compatibleCore(
                    systemName: details.systemName,
                    fileExtension: details.fileExtension,
                    archiveMemberNames: details.files.flatMap {
                        $0.archiveMembers.map(\.name)
                    }
                )
            hasLoaded = true
            isLoading = false
        } catch is CancellationError {
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func download(_ game: GameDetails) async {
        guard !isDownloading else {
            return
        }

        isDownloading = true
        downloadedFileURL = nil
        downloadErrorMessage = nil

        do {
            downloadedFileURL = try await service.downloadGame(game, in: session)
        } catch is CancellationError {
            // Cancellation is expected when the user leaves the details view.
        } catch {
            downloadErrorMessage = error.localizedDescription
        }

        isDownloading = false
    }

    func dismissDownloadResult() {
        downloadedFileURL = nil
        downloadErrorMessage = nil
    }

    func prepareToPlay(_ game: GameDetails) async -> LibretroRunRequest? {
        guard !isPreparingToPlay, let playbackCore else {
            return nil
        }

        isPreparingToPlay = true
        playbackErrorMessage = nil
        defer { isPreparingToPlay = false }

        do {
            let contentURL = try await service.prepareGameForPlay(
                game,
                in: session,
                supportedFileExtensions: playbackCore.fileExtensions
            )
            return LibretroRunRequest(
                title: game.name,
                coreID: playbackCore.id,
                contentURL: contentURL
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
}
