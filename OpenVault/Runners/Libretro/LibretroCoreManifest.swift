import Foundation

/// The reviewed catalog of Libretro cores embedded in OpenVault.
struct LibretroCoreManifest: Decodable, Sendable {
    struct Core: Decodable, Identifiable, Sendable {
        enum Status: String, Decodable, Sendable {
            case pipelineTest
            case bundled
            case planned
            case excluded
        }

        let id: String
        let displayName: String
        let status: Status
        let binaryName: String
        let systems: [String]
        let fileExtensions: [String]
        let capabilities: [String]
        let firmware: [Firmware]

        struct Firmware: Decodable, Sendable {
            let fileName: String
            let required: Bool
        }
    }

    let schemaVersion: Int
    let minimumMacOS: String
    let architecture: String
    let cores: [Core]

    func core(id: String) -> Core? {
        cores.first { $0.id == id }
    }

    func compatibleCore(
        systemName: String,
        fileExtension: String,
        archiveMemberNames: [String] = []
    ) -> Core? {
        let system = Self.systemIdentifier(for: systemName)
        let fileExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        return cores.first { core in
            guard core.status == .bundled, core.systems.contains(system) else {
                return false
            }
            guard fileExtension == "zip" else {
                return core.fileExtensions.contains(fileExtension)
            }
            guard !archiveMemberNames.isEmpty else {
                return true
            }
            return archiveMemberNames.contains { name in
                core.fileExtensions.contains(
                    URL(fileURLWithPath: name).pathExtension.lowercased()
                )
            }
        }
    }

    private static func systemIdentifier(for name: String) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "game boy", "nintendo game boy":
            "gb"
        case "game boy color", "nintendo game boy color":
            "gbc"
        default:
            name
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
        }
    }
}

enum LibretroInstallationError: LocalizedError {
    case missingManifest
    case unsupportedManifestVersion(Int)
    case missingCore(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            """
            OpenVault could not find its bundled Libretro manifest. Build the cores with \
            Scripts/build-libretro-cores.sh, then rebuild OpenVault.
            """
        case let .unsupportedManifestVersion(version):
            "This build contains Libretro manifest version \(version), which OpenVault does not support."
        case let .missingCore(name):
            """
            The bundled core \(name) is missing. Build the cores with \
            Scripts/build-libretro-cores.sh, then rebuild OpenVault.
            """
        case let .invalidManifest(reason):
            "OpenVault could not read its bundled Libretro manifest: \(reason)"
        }
    }
}

/// Resolves only cores shipped inside the signed application bundle.
struct LibretroInstallation: Sendable {
    let manifest: LibretroCoreManifest
    private let coresDirectory: URL

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let resourcesDirectory = bundle.resourceURL?
            .appending(path: "Libretro", directoryHint: .isDirectory)
            else {
            throw LibretroInstallationError.missingManifest
        }

        let manifestURL = resourcesDirectory.appending(path: "CoreManifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LibretroInstallationError.missingManifest
        }

        let manifest: LibretroCoreManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(LibretroCoreManifest.self, from: data)
        } catch {
            throw LibretroInstallationError.invalidManifest(error.localizedDescription)
        }

        guard manifest.schemaVersion == 1 else {
            throw LibretroInstallationError.unsupportedManifestVersion(manifest.schemaVersion)
        }

        let coresDirectory = bundle.builtInPlugInsURL?
            .appending(path: "Libretro", directoryHint: .isDirectory)
            ?? bundle.bundleURL
                .appending(path: "Contents/PlugIns/Libretro", directoryHint: .isDirectory)

        return Self(manifest: manifest, coresDirectory: coresDirectory)
    }

    func core(id: String) throws -> (LibretroCoreManifest.Core, URL) {
        guard let core = manifest.core(id: id) else {
            throw LibretroInstallationError.missingCore(id)
        }

        let binaryURL = coresDirectory.appending(path: core.binaryName)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw LibretroInstallationError.missingCore(core.displayName)
        }

        return (core, binaryURL)
    }

    func compatibleCore(
        systemName: String,
        fileExtension: String,
        archiveMemberNames: [String] = []
    ) -> LibretroCoreManifest.Core? {
        manifest.compatibleCore(
            systemName: systemName,
            fileExtension: fileExtension,
            archiveMemberNames: archiveMemberNames
        )
    }
}
