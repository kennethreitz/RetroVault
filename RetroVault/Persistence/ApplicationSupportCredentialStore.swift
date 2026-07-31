import Foundation

/// Persists the RomM client token inside RetroVault's sandbox container.
///
/// This is intentionally a temporary development store. The token is not
/// encrypted at rest beyond the protection provided by the user's account and
/// the app sandbox, so release builds should migrate back to Keychain.
actor ApplicationSupportCredentialStore: CredentialStoring {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    func loadToken() throws -> ClientToken? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard
            let data = try? Data(contentsOf: fileURL),
            let value = String(data: data, encoding: .utf8)
        else {
            throw ApplicationSupportCredentialStoreError.invalidData
        }

        return try ClientToken(rawValue: value)
    }

    func save(_ token: ClientToken) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        try Data(token.rawValue.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func removeToken() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static var defaultFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)

        return applicationSupportURL
            .appending(path: "RetroVault", directoryHint: .isDirectory)
            .appending(path: "romm-client-token")
    }
}

enum ApplicationSupportCredentialStoreError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        "RetroVault's stored RomM client token is unreadable."
    }
}
