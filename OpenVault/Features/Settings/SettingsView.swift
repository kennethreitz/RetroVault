import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Server") {
                switch model.destination {
                case let .library(session):
                    LabeledContent("Address", value: session.serverURL.value.absoluteString)
                    LabeledContent("User", value: session.username)

                    Button("Disconnect", role: .destructive) {
                        Task {
                            await model.disconnect()
                        }
                    }
                case .preparing, .connection:
                    Text("No RomM server is connected.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
