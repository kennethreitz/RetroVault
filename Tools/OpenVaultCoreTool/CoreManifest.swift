import Foundation

struct CoreManifest: Codable, Sendable {
    let schemaVersion: Int
    let minimumMacOS: String
    let architecture: String
    let cores: [Core]
}

extension CoreManifest {
    struct Core: Codable, Sendable {
        let id: String
        let displayName: String
        let status: Status
        let binaryName: String
        let systems: [String]
        let fileExtensions: [String]
        let loadsArchivesDirectly: Bool?
        let capabilities: [Capability]
        let firmware: [Firmware]
        let systemAssets: [SystemAsset]?
        let source: Source
        let license: License
        let build: Build
    }

    enum Status: String, Codable, Sendable {
        case pipelineTest
        case bundled
        case planned
        case excluded

        var participatesInBuild: Bool {
            self == .pipelineTest || self == .bundled
        }
    }

    enum Capability: String, Codable, CaseIterable, Sendable {
        case softwareVideo
        case hardwareVideo
        case audio
        case retropad
        case keyboard
        case pointer
        case serialization
        case diskControl
        case virtualFileSystem
        case subsystemContent
    }

    struct Firmware: Codable, Sendable {
        let id: String
        let fileName: String
        let description: String
        let required: Bool
        let sha256: [String]
        let sha1: [String]?
    }

    struct Source: Codable, Sendable {
        let repository: String
        let revision: String
        let patches: [String]?
        let licenseFile: String
        let submodules: [String]?
    }

    struct License: Codable, Sendable {
        let spdx: String
        let redistributionStatus: RedistributionStatus
        let noticeURL: String
    }

    enum RedistributionStatus: String, Codable, Sendable {
        case approved
        case reviewRequired
        case prohibited
    }

    struct Build: Codable, Sendable {
        let workingDirectory: String
        let configure: Command?
        let executable: String
        let arguments: [String]
        let output: String
    }

    struct Command: Codable, Sendable {
        let executable: String
        let arguments: [String]
    }

    struct SystemAsset: Codable, Sendable {
        let sourcePath: String
        let destinationPath: String
    }
}

enum ManifestLoader {
    static func load(from url: URL) throws -> CoreManifest {
        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CoreToolError.couldNotRead(url, reason: error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(CoreManifest.self, from: data)
        } catch {
            throw CoreToolError.invalidJSON(reason: error.localizedDescription)
        }
    }
}

enum ManifestValidator {
    static func validate(_ manifest: CoreManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw CoreToolError.validation(
                "Unsupported schemaVersion \(manifest.schemaVersion); expected 1."
            )
        }

        guard manifest.architecture == "arm64" else {
            throw CoreToolError.validation(
                "The core bundle architecture must be arm64."
            )
        }

        guard isValidMacOSVersion(manifest.minimumMacOS) else {
            throw CoreToolError.validation(
                "minimumMacOS must contain a major and minor numeric version."
            )
        }

        guard !manifest.cores.isEmpty else {
            throw CoreToolError.validation("The manifest must contain at least one core.")
        }

        var identifiers = Set<String>()
        var binaryNames = Set<String>()

        for core in manifest.cores {
            try validate(core)

            guard identifiers.insert(core.id).inserted else {
                throw CoreToolError.validation("Duplicate core id: \(core.id).")
            }

            guard binaryNames.insert(core.binaryName).inserted else {
                throw CoreToolError.validation(
                    "Duplicate core binaryName: \(core.binaryName)."
                )
            }
        }
    }

    private static func validate(_ core: CoreManifest.Core) throws {
        guard isSlug(core.id) else {
            throw CoreToolError.validation(
                "Core id \(core.id) must use lowercase ASCII letters, numbers, and hyphens."
            )
        }

        guard !core.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreToolError.validation("\(core.id) has an empty displayName.")
        }

        guard isSafeFileName(core.binaryName), core.binaryName.hasSuffix("_libretro.dylib") else {
            throw CoreToolError.validation(
                "\(core.id) binaryName must be a plain *_libretro.dylib filename."
            )
        }

        guard isHTTPSURL(core.source.repository),
              core.source.repository.hasSuffix(".git")
        else {
            throw CoreToolError.validation(
                "\(core.id) source.repository must be an HTTPS Git URL ending in .git."
            )
        }

        guard core.source.revision.count == 40,
              core.source.revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw CoreToolError.validation(
                "\(core.id) source.revision must be a full lowercase Git commit."
            )
        }

        for patch in core.source.patches ?? [] {
            guard patch.count == 40,
                  patch.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                throw CoreToolError.validation(
                    "\(core.id) source.patches must contain full lowercase Git commits."
                )
            }
        }

        guard isSafeRelativePath(core.source.licenseFile, allowCurrentDirectory: false) else {
            throw CoreToolError.validation(
                "\(core.id) source.licenseFile must be a safe relative path."
            )
        }

        for submodule in core.source.submodules ?? [] {
            guard isSafeRelativePath(submodule, allowCurrentDirectory: false) else {
                throw CoreToolError.validation(
                    "\(core.id) source.submodules must contain safe relative paths."
                )
            }
        }

        guard isHTTPSURL(core.license.noticeURL) else {
            throw CoreToolError.validation(
                "\(core.id) license.noticeURL must use HTTPS."
            )
        }

        if core.status.participatesInBuild,
           core.license.redistributionStatus != .approved
        {
            throw CoreToolError.validation(
                "\(core.id) cannot be built until redistribution is approved."
            )
        }

        guard isSafeRelativePath(
            core.build.workingDirectory,
            allowCurrentDirectory: true
        ) else {
            throw CoreToolError.validation(
                "\(core.id) build.workingDirectory must be a safe relative path."
            )
        }

        guard core.build.executable.hasPrefix("/"),
              !containsControlCharacter(core.build.executable)
        else {
            throw CoreToolError.validation(
                "\(core.id) build.executable must be an absolute path."
            )
        }

        guard !core.build.arguments.contains(where: containsControlCharacter) else {
            throw CoreToolError.validation(
                "\(core.id) build arguments cannot contain control characters."
            )
        }

        if let configure = core.build.configure {
            guard configure.executable.hasPrefix("/"),
                  !containsControlCharacter(configure.executable),
                  !configure.arguments.contains(where: containsControlCharacter)
            else {
                throw CoreToolError.validation(
                    "\(core.id) configure command must use an absolute executable and safe arguments."
                )
            }
        }

        guard isSafeRelativePath(core.build.output, allowCurrentDirectory: false) else {
            throw CoreToolError.validation(
                "\(core.id) build.output must be a safe relative path."
            )
        }

        for asset in core.systemAssets ?? [] {
            guard
                isSafeRelativePath(asset.sourcePath, allowCurrentDirectory: false),
                isSafeRelativePath(asset.destinationPath, allowCurrentDirectory: false)
            else {
                throw CoreToolError.validation(
                    "\(core.id) system assets must use safe relative paths."
                )
            }
        }

        guard Set(core.capabilities).count == core.capabilities.count else {
            throw CoreToolError.validation(
                "\(core.id) contains duplicate frontend capabilities."
            )
        }

        guard normalizedValues(core.systems),
              normalizedValues(core.fileExtensions)
        else {
            throw CoreToolError.validation(
                "\(core.id) systems and fileExtensions must be unique lowercase identifiers."
            )
        }

        for firmware in core.firmware {
            guard isSlug(firmware.id), isSafeFileName(firmware.fileName) else {
                throw CoreToolError.validation(
                    "\(core.id) has an invalid firmware identifier or filename."
                )
            }

            guard firmware.sha256.allSatisfy({
                $0.count == 64 && $0.allSatisfy(\.isHexDigit)
            }) else {
                throw CoreToolError.validation(
                    "\(core.id) firmware SHA-256 values must contain 64 hexadecimal characters."
                )
            }

            guard (firmware.sha1 ?? []).allSatisfy({
                $0.count == 40 && $0.allSatisfy(\.isHexDigit)
            }) else {
                throw CoreToolError.validation(
                    "\(core.id) firmware SHA-1 values must contain 40 hexadecimal characters."
                )
            }
        }
    }

    private static func isValidMacOSVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { Int($0) != nil }
    }

    private static func isSlug(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }

        return value.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-")
        }
    }

    private static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !containsControlCharacter(value)
    }

    private static func isSafeRelativePath(
        _ value: String,
        allowCurrentDirectory: Bool
    ) -> Bool {
        if allowCurrentDirectory, value == "." {
            return true
        }

        guard !value.isEmpty, !value.hasPrefix("/") else {
            return false
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        } && !containsControlCharacter(value)
    }

    private static func isHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else {
            return false
        }

        return components.scheme == "https"
            && components.host != nil
            && components.user == nil
            && components.password == nil
    }

    private static func normalizedValues(_ values: [String]) -> Bool {
        Set(values).count == values.count
            && values.allSatisfy {
                !$0.isEmpty
                    && $0 == $0.lowercased()
                    && !$0.hasPrefix(".")
                    && !containsControlCharacter($0)
            }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum CoreToolError: LocalizedError {
    case usage(String)
    case couldNotRead(URL, reason: String)
    case invalidJSON(reason: String)
    case validation(String)
    case commandFailed(command: String, status: Int32, output: String)
    case build(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            message
        case let .couldNotRead(url, reason):
            "Could not read \(url.path): \(reason)"
        case let .invalidJSON(reason):
            "The core manifest is not valid JSON: \(reason)"
        case let .validation(message):
            "Core manifest validation failed: \(message)"
        case let .commandFailed(command, status, output):
            """
            Command failed with status \(status): \(command)
            \(output)
            """
        case let .build(message):
            "Core build failed: \(message)"
        }
    }
}
