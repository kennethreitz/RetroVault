import SwiftUI

struct RootScene: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.destination {
            case .preparing:
                ProgressView("Opening OpenVault…")
                    .frame(minWidth: 520, minHeight: 380)

            case .connection:
                ServerConnectionView(model: model)

            case let .library(session):
                LibraryView(
                    session: session,
                    service: model.libraryService
                )
            }
        }
        .task {
            await model.restore()
        }
    }
}
