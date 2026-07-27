import SwiftUI

struct RootScene: View {
    let model: AppModel

    @AppStorage(BigPictureScene.launchesAutomaticallyPreferenceKey)
    private var launchesBigPictureAutomatically = false
    @State private var automaticLaunchGate = BigPictureAutomaticLaunchGate()
    @State private var isPresentingBigPicture = false

    var body: some View {
        Group {
            if isPresentingBigPicture, let libraryModel = model.libraryModel {
                BigPictureView(
                    model: libraryModel,
                    onExitRequested: {
                        isPresentingBigPicture = false
                    }
                )
            } else {
                switch model.destination {
                case .preparing:
                    ProgressView("Opening OpenVault…")
                        .frame(minWidth: 520, minHeight: 380)

                case .connection:
                    ServerConnectionView(model: model)

                case .library:
                    if let libraryModel = model.libraryModel {
                        LibraryView(
                            model: libraryModel,
                            onOpenBigPicture: {
                                isPresentingBigPicture = true
                            }
                        )
                    } else {
                        ProgressView("Opening Library…")
                            .frame(minWidth: 520, minHeight: 380)
                    }
                }
            }
        }
        .task {
            await model.restore()
        }
        .task(id: model.libraryModel != nil) {
            guard automaticLaunchGate.shouldOpen(
                isLibraryAvailable: model.libraryModel != nil,
                preferenceEnabled: launchesBigPictureAutomatically
            ) else {
                return
            }

            await Task.yield()
            isPresentingBigPicture = true
        }
    }
}

struct BigPictureAutomaticLaunchGate: Sendable {
    private(set) var hasHandledLibraryAvailability = false

    mutating func shouldOpen(
        isLibraryAvailable: Bool,
        preferenceEnabled: Bool
    ) -> Bool {
        guard isLibraryAvailable, !hasHandledLibraryAvailability else {
            return false
        }

        hasHandledLibraryAvailability = true
        return preferenceEnabled
    }
}
