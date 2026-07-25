import SwiftUI

struct ServerConnectionView: View {
    let model: AppModel

    @State private var serverURL = ""
    @State private var pairingCode = ""

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (try? PairingCode(pairingCode)) != nil
            && !model.isConnecting
    }

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Connect to RomM")
                    .font(.largeTitle.weight(.semibold))

                Text("Pair OpenVault with the server that already holds your library.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Form {
                TextField("Server URL", text: $serverURL, prompt: Text("https://romm.example.com"))
                    .textContentType(.URL)

                TextField("Pairing code", text: $pairingCode, prompt: Text("A1B2C3D4"))
                    .textContentType(.oneTimeCode)
                    .monospaced()
                    .onChange(of: pairingCode) { _, newValue in
                        pairingCode = String(
                            newValue
                                .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                                .prefix(8)
                        )
                    }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)

            if let connectionError = model.connectionError {
                Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            HStack {
                Link(
                    "Create a client token in RomM",
                    destination: URL(string: "https://docs.romm.app/latest/developers/client-api-tokens/")!
                )

                Spacer()

                Button {
                    Task {
                        await model.connect(serverURL: serverURL, pairingCode: pairingCode)
                    }
                } label: {
                    if model.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
            .frame(maxWidth: 520)

            Text("OpenVault needs me.read, platforms.read, roms.read, and collections.read. The token is stored only in your Mac's Keychain.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(48)
        .frame(minWidth: 680, minHeight: 520)
    }
}
