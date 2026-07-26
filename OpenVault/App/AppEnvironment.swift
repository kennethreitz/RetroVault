import Foundation
import Nuke

struct ArtworkCacheProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let failedCount: Int
}

protocol ArtworkCaching: Sendable {
    func cacheArtwork(
        for games: [GameSummary],
        in session: ServerSession,
        using service: any LibraryServing,
        onProgress: @escaping @Sendable (ArtworkCacheProgress) async -> Void
    ) async
}

struct DisabledArtworkCache: ArtworkCaching {
    func cacheArtwork(
        for games: [GameSummary],
        in session: ServerSession,
        using service: any LibraryServing,
        onProgress: @escaping @Sendable (ArtworkCacheProgress) async -> Void
    ) async {}
}

actor NukeArtworkCache: ArtworkCaching {
    private let pipeline: ImagePipeline
    private let maximumConcurrentRequestCount: Int

    init(
        pipeline: ImagePipeline = .shared,
        maximumConcurrentRequestCount: Int = 4
    ) {
        self.pipeline = pipeline
        self.maximumConcurrentRequestCount = max(1, maximumConcurrentRequestCount)
    }

    func cacheArtwork(
        for games: [GameSummary],
        in session: ServerSession,
        using service: any LibraryServing,
        onProgress: @escaping @Sendable (ArtworkCacheProgress) async -> Void
    ) async {
        let candidateCount = Set(games.compactMap(\.coverURL)).count
        do {
            let urlRequests = try await service.artworkRequests(
                for: games,
                in: session
            )
            let requests = urlRequests.map { urlRequest in
                var request = ImageRequest(urlRequest: urlRequest)
                request.priority = .low
                return request
            }
            let totalCount = requests.count
            guard totalCount > 0 else {
                await onProgress(
                    ArtworkCacheProgress(
                        completedCount: 0,
                        totalCount: 0,
                        failedCount: 0
                    )
                )
                return
            }

            let missingRequests = requests.filter {
                !pipeline.cache.containsData(for: $0)
            }
            var completedCount = totalCount - missingRequests.count
            var failedCount = 0
            await onProgress(
                ArtworkCacheProgress(
                    completedCount: completedCount,
                    totalCount: totalCount,
                    failedCount: failedCount
                )
            )

            guard !missingRequests.isEmpty else {
                return
            }

            await withTaskGroup(of: Bool.self) { group in
                var iterator = missingRequests.makeIterator()
                let initialRequestCount = min(
                    maximumConcurrentRequestCount,
                    missingRequests.count
                )

                for _ in 0..<initialRequestCount {
                    guard let request = iterator.next() else {
                        break
                    }
                    add(request, to: &group)
                }

                while let succeeded = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }

                    completedCount += 1
                    if !succeeded {
                        failedCount += 1
                    }

                    if completedCount.isMultiple(of: 50)
                        || completedCount == totalCount
                    {
                        await onProgress(
                            ArtworkCacheProgress(
                                completedCount: completedCount,
                                totalCount: totalCount,
                                failedCount: failedCount
                            )
                        )
                    }

                    if let request = iterator.next() {
                        add(request, to: &group)
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await onProgress(
                ArtworkCacheProgress(
                    completedCount: candidateCount,
                    totalCount: candidateCount,
                    failedCount: candidateCount
                )
            )
            OpenVaultLog.library.error(
                "Could not prepare the artwork cache: \(error.localizedDescription)"
            )
        }
    }

    private func add(
        _ request: ImageRequest,
        to group: inout TaskGroup<Bool>
    ) {
        let pipeline = self.pipeline
        group.addTask {
            do {
                _ = try await pipeline.data(for: request)
                return true
            } catch {
                return false
            }
        }
    }
}

/// Dependencies assembled at the application boundary.
struct AppEnvironment: Sendable {
    let serverConnection: any ServerConnecting
    let library: any LibraryServing
    let artworkCache: any ArtworkCaching

    static func live() -> AppEnvironment {
        let api = URLSessionRomMClient()
        let credentials = ApplicationSupportCredentialStore()
        let configuration = UserDefaultsServerConfigurationStore()
        let libraryCache = SwiftDataLibraryCache()
        ImagePipeline.shared = ImagePipeline(
            configuration: .withDataCache(
                name: "org.kennethreitz.OpenVault.Artwork",
                sizeLimit: 10 * 1_024 * 1_024 * 1_024
            )
        )

        return AppEnvironment(
            serverConnection: ServerConnectionService(
                api: api,
                credentialStore: credentials,
                configurationStore: configuration,
                libraryCache: libraryCache
            ),
            library: RomMLibraryService(
                api: api,
                credentialStore: credentials,
                cache: libraryCache,
                purgeArtworkCache: {
                    ImagePipeline.shared.cache.removeAll()
                }
            ),
            artworkCache: NukeArtworkCache()
        )
    }
}
