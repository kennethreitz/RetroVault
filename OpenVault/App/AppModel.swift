import Foundation
import Observation
import OSLog

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
    private(set) var libraryModel: LibraryModel?
    private(set) var isConnecting = false
    var connectionError: String?

    var libraryService: any LibraryServing {
        environment.library
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func restore() async {
        guard case .preparing = destination else {
            return
        }

        OpenVaultLog.application.debug("Restoring the previous OpenVault session")
        do {
            if let session = try await environment.serverConnection.restoredSession() {
                showLibrary(session)
                OpenVaultLog.connection.notice("Restored a paired RomM session")
            } else {
                destination = .connection
                OpenVaultLog.connection.info("No paired RomM session is stored")
            }
        } catch {
            connectionError = error.localizedDescription
            destination = .connection
            OpenVaultLog.connection.error(
                "Could not restore the paired session: \(error.localizedDescription)"
            )
        }
    }

    func connect(serverURL: String, pairingCode: String) async {
        guard !isConnecting else {
            return
        }

        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        OpenVaultLog.connection.notice("Pairing with a RomM server")
        do {
            let session = try await environment.serverConnection.pair(
                serverURL: serverURL,
                pairingCode: pairingCode
            )
            showLibrary(session)
            OpenVaultLog.connection.notice("Paired with RomM successfully")
        } catch {
            connectionError = error.localizedDescription
            OpenVaultLog.connection.error(
                "RomM pairing failed: \(error.localizedDescription)"
            )
        }
    }

    func disconnect() async {
        OpenVaultLog.connection.notice("Disconnecting the RomM server")
        libraryModel?.cancelBackgroundWork()
        do {
            try await environment.serverConnection.disconnect()
            connectionError = nil
            libraryModel = nil
            destination = .connection
            OpenVaultLog.connection.notice("Disconnected the RomM server")
        } catch {
            connectionError = error.localizedDescription
            OpenVaultLog.connection.error(
                "Could not disconnect RomM: \(error.localizedDescription)"
            )
        }
    }

    private func showLibrary(_ session: ServerSession) {
        libraryModel = LibraryModel(
            session: session,
            service: environment.library,
            artworkCache: environment.artworkCache
        )
        destination = .library(session)
    }
}
