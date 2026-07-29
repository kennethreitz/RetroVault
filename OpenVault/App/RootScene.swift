import AppKit
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

            case .library:
                if let libraryModel = model.libraryModel {
                    BigPictureView(
                        model: libraryModel,
                        onExitRequested: {
                            NSApplication.shared.terminate(nil)
                        }
                    )
                } else {
                    ProgressView("Opening Library…")
                        .frame(minWidth: 520, minHeight: 380)
                }
            }
        }
        .task {
            await model.restore()
        }
    }
}
