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
