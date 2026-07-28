import Foundation

enum RomMAPIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case downloadUnavailable
    case rejectedPairingCode
    case server(statusCode: Int)
    case transport(URLError)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned a response OpenVault could not understand."
        case .unauthorized:
            "RomM rejected the client token."
        case .forbidden:
            "The paired token does not have the permissions OpenVault needs."
        case .notFound:
            "This server does not expose the expected RomM API."
        case .downloadUnavailable:
            "RomM found this game, but its ROM file is unavailable. The server's library record may be out of sync with its filesystem."
        case .rejectedPairingCode:
            "That pairing code is invalid or has expired. Generate a new code in RomM and try again."
        case let .server(statusCode):
            "RomM returned HTTP \(statusCode)."
        case let .transport(error):
            "OpenVault could not reach RomM: \(error.localizedDescription)"
        case .decoding:
            "RomM returned data in an unsupported format."
        }
    }
}

extension RomMAPIError {
    /// The transport failures that actually prove RomM could not be reached.
    ///
    /// Everything else the server answered — a rejected token, a missing
    /// route, an HTTP 500 — is evidence the connection *works*, so it must not
    /// put OpenVault into an offline state. Cancellation never appears here: it
    /// is mapped to `CancellationError` at the transport boundary.
    static let unreachableTransportCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .networkConnectionLost,
        .notConnectedToInternet,
        .secureConnectionFailed,
        .timedOut,
    ]

    /// Whether a failure is evidence that the server is unreachable, rather
    /// than evidence that some individual request went wrong.
    static func indicatesServerUnreachable(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            false
        case let error as RomMAPIError:
            if case let .transport(urlError) = error {
                unreachableTransportCodes.contains(urlError.code)
            } else {
                false
            }
        case let error as URLError:
            unreachableTransportCodes.contains(error.code)
        default:
            false
        }
    }
}
