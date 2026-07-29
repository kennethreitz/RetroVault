import Foundation

/// The reviewed catalog of Libretro cores embedded in OpenVault.
struct LibretroCoreManifest: Decodable, Sendable {
    struct Core: Decodable, Identifiable, Sendable {
        enum Status: String, Decodable, Sendable {
            case pipelineTest
            case bundled
            case experimental
            case planned
            case excluded

            /// Whether a core may be chosen for a user's game. Reviewed cores
            /// always qualify; experimental ones ship in the app but stay out
            /// of the way until they are asked for.
            func isOffered(includingExperimental: Bool) -> Bool {
                switch self {
                case .bundled:
                    true
                case .experimental:
                    includingExperimental
                case .pipelineTest, .planned, .excluded:
                    false
                }
            }
        }

        let id: String
        let displayName: String
        let status: Status
        let binaryName: String
        let systems: [String]
        let fileExtensions: [String]
        let loadsArchivesDirectly: Bool?
        let capabilities: [String]
        let firmware: [Firmware]

        /// Core artifacts keep the manifest snapshot they were built with.
        /// Safety downgrades must still take effect when an existing binary
        /// bundle is reused instead of rebuilt.
        var availabilityStatus: Status {
            switch id {
            case "libretro-fake08":
                .experimental
            default:
                status
            }
        }

        func isOffered(includingExperimental: Bool) -> Bool {
            availabilityStatus.isOffered(
                includingExperimental: includingExperimental
            )
        }

        struct Firmware: Decodable, Sendable {
            let id: String
            let fileName: String
            let description: String
            let required: Bool
            let sha256: [String]
            let sha1: [String]?
        }
    }

    let schemaVersion: Int
    let minimumMacOS: String
    let architecture: String
    let cores: [Core]

    func core(id: String) -> Core? {
        cores.first { $0.id == id }
    }

    /// Returns whether OpenVault ships a reviewed core for the named RomM system.
    func supportsSystem(
        named systemName: String,
        includingExperimental: Bool = LibretroCorePreferences.enablesExperimentalCores()
    ) -> Bool {
        let system = Self.systemIdentifier(for: systemName)
        return cores.contains {
            $0.isOffered(includingExperimental: includingExperimental)
                && $0.systems.contains(system)
        }
    }

    func compatibleCore(
        systemName: String,
        fileExtension: String,
        archiveMemberNames: [String] = [],
        contentFileNames: [String] = [],
        includingExperimental: Bool = LibretroCorePreferences.enablesExperimentalCores()
    ) -> Core? {
        let system = Self.systemIdentifier(for: systemName)
        let fileExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let contentFileExtensions = Set(
            contentFileNames.map {
                URL(fileURLWithPath: $0).pathExtension.lowercased()
            }
            .filter { !$0.isEmpty }
        )

        return cores.first { core in
            guard
                core.isOffered(includingExperimental: includingExperimental),
                core.systems.contains(system)
            else {
                return false
            }
            if fileExtension.isEmpty,
               contentFileExtensions.isEmpty,
               archiveMemberNames.isEmpty
            {
                // Offline library summaries intentionally omit file metadata.
                // A reviewed system/core mapping is still enough to locate the
                // already-downloaded file before playback.
                return true
            }
            guard fileExtension == "zip" else {
                return core.fileExtensions.contains(fileExtension)
                    || !contentFileExtensions.isDisjoint(
                        with: core.fileExtensions
                    )
            }
            if core.loadsArchivesDirectly == true,
               core.fileExtensions.contains(fileExtension)
            {
                return true
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
        case "game boy advance", "nintendo game boy advance":
            "gba"
        case "dreamcast", "sega dreamcast":
            "dreamcast"
        case "nes", "famicom", "nintendo famicom",
             "nintendo entertainment system", "nintendo nes":
            "nes"
        case "snes", "super famicom", "nintendo super famicom",
             "super nintendo", "super nintendo entertainment system",
             "nintendo super nintendo entertainment system":
            "snes"
        case "master system", "sega master system",
             "sega master system/mark iii":
            "sms"
        case "game gear", "sega game gear":
            "gg"
        case "sg-1000", "sega sg-1000":
            "sg-1000"
        case "colecovision", "coleco vision", "coleco colecovision":
            "colecovision"
        case "genesis", "mega drive", "sega genesis", "sega mega drive",
             "sega mega drive/genesis":
            "genesis"
        case "sega cd", "mega cd", "sega mega cd":
            "sega-cd"
        case "sega 32x", "mega 32x":
            "sega-32x"
        case "atari 2600":
            "atari-2600"
        case "atari 5200":
            "atari-5200"
        case "atari 7800":
            "atari-7800"
        case "virtual boy", "nintendo virtual boy":
            "virtual-boy"
        case "neo geo pocket", "snk neo geo pocket":
            "ngp"
        case "neo geo pocket color", "snk neo geo pocket color":
            "ngpc"
        case "wonderswan", "bandai wonderswan":
            "ws"
        case "wonderswan color", "bandai wonderswan color":
            "wsc"
        case "pokemon mini", "pokémon mini", "nintendo pokemon mini",
             "nintendo pokémon mini":
            "pokemon-mini"
        case "playstation", "playstation 1", "sony playstation", "ps1", "psx":
            "psx"
        case "playstation portable", "sony playstation portable", "psp":
            "psp"
        case "pc engine", "nec pc engine", "turbografx-16", "turbografx 16",
             "turbo grafx 16", "turbografx-16/pc engine", "nec turbografx-16":
            "pce"
        case "pc engine cd", "pc engine cd-rom2", "pc engine cd-rom²",
             "turbografx-cd", "turbografx cd", "nec pc engine cd":
            "pce-cd"
        case "pc engine supergrafx", "supergrafx", "nec supergrafx":
            "sgx"
        case "gamecube", "nintendo gamecube", "nintendo game cube",
             "gcn", "ngc":
            "gamecube"
        case "nintendo 64", "n64":
            "n64"
        case "wii", "nintendo wii":
            "wii"
        case "nintendo ds", "nds":
            "nds"
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

        let coresDirectory = bundle.builtInPlugInsURL?
            .appending(path: "Libretro", directoryHint: .isDirectory)
            ?? bundle.bundleURL
                .appending(path: "Contents/PlugIns/Libretro", directoryHint: .isDirectory)

        return try Self(
            manifestURL: manifestURL,
            coresDirectory: coresDirectory
        )
    }

    /// Creates an installation from explicit manifest and core locations.
    ///
    /// OpenVault uses this entry point for integration tests against the same
    /// reviewed core artifacts that are later embedded in the application.
    init(manifestURL: URL, coresDirectory: URL) throws {
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(
                LibretroCoreManifest.self,
                from: data
            )
        } catch {
            throw LibretroInstallationError.invalidManifest(error.localizedDescription)
        }

        guard manifest.schemaVersion == 1 else {
            throw LibretroInstallationError.unsupportedManifestVersion(manifest.schemaVersion)
        }

        self.coresDirectory = coresDirectory
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
        archiveMemberNames: [String] = [],
        contentFileNames: [String] = [],
        includingExperimental: Bool =
            LibretroCorePreferences.enablesExperimentalCores()
    ) -> LibretroCoreManifest.Core? {
        manifest.compatibleCore(
            systemName: systemName,
            fileExtension: fileExtension,
            archiveMemberNames: archiveMemberNames,
            contentFileNames: contentFileNames,
            includingExperimental: includingExperimental
        )
    }
}


/// Opt-in for cores that are built and shipped but have not met the reviewed
/// bar in `CoreManifest.json`.
///
/// The manifest stays the single place a core's standing is recorded; this
/// preference only decides whether the experimental ones are offered.
enum LibretroCorePreferences {
    static let enablesExperimentalCoresKey = "libretro.cores.experimental.v1"
    static let enabledByDefault = false

    static func enablesExperimentalCores(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: enablesExperimentalCoresKey) as? Bool
            ?? enabledByDefault
    }
}
