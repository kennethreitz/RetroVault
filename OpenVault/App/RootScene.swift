import SwiftUI

struct RootScene: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @AppStorage(BigPictureScene.launchesAutomaticallyPreferenceKey)
    private var launchesBigPictureAutomatically = false
    @State private var automaticLaunchGate = BigPictureAutomaticLaunchGate()

    var body: some View {
        Group {
            switch model.destination {
            case .preparing:
                ProgressView("Opening OpenVault…")
                    .frame(minWidth: 520, minHeight: 380)

            case .connection:
                ServerConnectionView(model: model)

            case .library:
                if let libraryModel = model.libraryModel {
                    LibraryView(model: libraryModel)
                } else {
                    ProgressView("Opening Library…")
                        .frame(minWidth: 520, minHeight: 380)
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
            openWindow(id: BigPictureScene.id)
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
