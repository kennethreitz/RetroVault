import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Destination {
        case preparing
        case connection
        case library(ServerSession)
    }

    private let environment: AppEnvironment

    private(set) var destination: Destination = .preparing
    private(set) var isConnecting = false
    var connectionError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var libraryService: any LibraryServing {
        environment.library
    }

    func restore() async {
        guard case .preparing = destination else {
            return
        }

        do {
            if let session = try await environment.serverConnection.restoredSession() {
                destination = .library(session)
            } else {
                destination = .connection
            }
        } catch {
            connectionError = error.localizedDescription
            destination = .connection
        }
    }

    func connect(serverURL: String, pairingCode: String) async {
        guard !isConnecting else {
            return
        }

        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            let session = try await environment.serverConnection.pair(
                serverURL: serverURL,
                pairingCode: pairingCode
            )
            destination = .library(session)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func disconnect() async {
        do {
            try await environment.serverConnection.disconnect()
            connectionError = nil
            destination = .connection
        } catch {
            connectionError = error.localizedDescription
        }
    }
}
