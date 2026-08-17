import Foundation

struct CoreBuildOptions: Sendable {
    let manifestURL: URL
    let outputDirectory: URL
    let workDirectory: URL
    let selectedCoreIDs: Set<String>
    let signingIdentity: String
}

struct CoreBuildReceipt: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let architecture: String
    let minimumMacOS: String
    let signing: Signing
    let cores: [Core]

    struct Signing: Codable, Sendable {
        let mode: String
        let identity: String?
    }

    struct Core: Codable, Sendable {
        struct LocalPatch: Codable, Sendable {
            let path: String
            let sha256: String
        }

        let id: String
        let displayName: String
        let binaryName: String
        let sourceRepository: String
        let sourceRevision: String
        let sourcePatches: [String]
        let localPatches: [LocalPatch]
        let sha256: String
        let licenseSPDX: String
        let licenseFile: String
    }
}

enum CoreBuilder {
    static func build(
        manifest: CoreManifest,
        options: CoreBuildOptions
    ) throws -> CoreBuildReceipt {
        let fileManager = FileManager.default
        try requireEmptyDirectory(options.outputDirectory)
        try fileManager.createDirectory(
            at: options.workDirectory,
            withIntermediateDirectories: true
        )

        let buildable = try selectedCores(
            from: manifest,
            selectedIDs: options.selectedCoreIDs
        )

        let coresDirectory = options.outputDirectory.appending(path: "Cores")
        let licensesDirectory = options.outputDirectory.appending(path: "Licenses")
        let systemDirectory = options.outputDirectory.appending(path: "System")
        try fileManager.createDirectory(
            at: coresDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: licensesDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: systemDirectory,
            withIntermediateDirectories: true
        )

        var receipts = [CoreBuildReceipt.Core]()

        for core in buildable {
            print("Building \(core.displayName) from \(core.source.revision)…")

            let coreWorkDirectory = options.workDirectory.appending(path: core.id)
            guard !fileManager.fileExists(atPath: coreWorkDirectory.path) else {
                throw CoreToolError.build(
                    "The work directory already contains \(core.id): "
                        + coreWorkDirectory.path
                )
            }

            let sourceDirectory = coreWorkDirectory.appending(path: "source")
            try fileManager.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )

            try clone(
                core,
                into: sourceDirectory,
                manifestDirectory: options.manifestURL.deletingLastPathComponent()
            )

            let buildDirectory = sourceDirectory.appending(
                path: core.build.workingDirectory,
                directoryHint: .isDirectory
            )
            if let configure = core.build.configure {
                try run(
                    configure.executable,
                    arguments: configure.arguments,
                    currentDirectory: buildDirectory,
                    environment: [
                        "MACOSX_DEPLOYMENT_TARGET": manifest.minimumMacOS,
                        "ZERO_AR_DATE": "1",
                    ]
                )
            }
            try run(
                core.build.executable,
                arguments: core.build.arguments,
                currentDirectory: buildDirectory,
                environment: [
                    "MACOSX_DEPLOYMENT_TARGET": manifest.minimumMacOS,
                    "ZERO_AR_DATE": "1",
                ]
            )

            let sourceBinary = buildDirectory.appending(path: core.build.output)
            guard fileManager.fileExists(atPath: sourceBinary.path) else {
                throw CoreToolError.build(
                    "\(core.id) did not produce \(sourceBinary.path)."
                )
            }

            try validateBinary(sourceBinary, coreID: core.id)

            let destinationBinary = coresDirectory.appending(path: core.binaryName)
            try fileManager.copyItem(at: sourceBinary, to: destinationBinary)
            try sign(destinationBinary, identity: options.signingIdentity)
            try verifySignature(destinationBinary)

            let sourceLicense = sourceDirectory.appending(
                path: core.source.licenseFile
            )
            guard fileManager.fileExists(atPath: sourceLicense.path) else {
                throw CoreToolError.build(
                    "\(core.id) is missing its declared license file "
                        + core.source.licenseFile
                )
            }

            let coreLicenseDirectory = licensesDirectory.appending(path: core.id)
            try fileManager.createDirectory(
                at: coreLicenseDirectory,
                withIntermediateDirectories: true
            )
            let destinationLicense = coreLicenseDirectory.appending(
                path: sourceLicense.lastPathComponent
            )
            try fileManager.copyItem(at: sourceLicense, to: destinationLicense)

            for asset in core.systemAssets ?? [] {
                let sourceAsset = sourceDirectory.appending(path: asset.sourcePath)
                guard fileManager.fileExists(atPath: sourceAsset.path) else {
                    throw CoreToolError.build(
                        "\(core.id) is missing its declared system asset "
                            + asset.sourcePath
                    )
                }
                let destinationAsset = systemDirectory.appending(
                    path: asset.destinationPath
                )
                try fileManager.createDirectory(
                    at: destinationAsset.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !fileManager.fileExists(atPath: destinationAsset.path) else {
                    throw CoreToolError.build(
                        "\(core.id) system asset destination already exists: "
                            + asset.destinationPath
                    )
                }
                try fileManager.copyItem(at: sourceAsset, to: destinationAsset)
            }

            receipts.append(
                CoreBuildReceipt.Core(
                    id: core.id,
                    displayName: core.displayName,
                    binaryName: core.binaryName,
                    sourceRepository: core.source.repository,
                    sourceRevision: core.source.revision,
                    sourcePatches: core.source.patches ?? [],
                    localPatches: (core.source.localPatches ?? []).map {
                        .init(path: $0.path, sha256: $0.sha256)
                    },
                    sha256: try sha256(of: destinationBinary),
                    licenseSPDX: core.license.spdx,
                    licenseFile: "Licenses/\(core.id)/\(sourceLicense.lastPathComponent)"
                )
            )
        }

        let manifestDestination = options.outputDirectory.appending(
            path: "CoreManifest.json"
        )
        try fileManager.copyItem(at: options.manifestURL, to: manifestDestination)

        let receipt = CoreBuildReceipt(
            schemaVersion: 1,
            generatedAt: Date(),
            architecture: manifest.architecture,
            minimumMacOS: manifest.minimumMacOS,
            signing: .init(
                mode: options.signingIdentity == "-" ? "adHoc" : "developerID",
                identity: options.signingIdentity == "-" ? nil : options.signingIdentity
            ),
            cores: receipts
        )
        try write(receipt, to: options.outputDirectory.appending(path: "BuildReceipt.json"))

        return receipt
    }

    private static func selectedCores(
        from manifest: CoreManifest,
        selectedIDs: Set<String>
    ) throws -> [CoreManifest.Core] {
        if !selectedIDs.isEmpty {
            let knownIDs = Set(manifest.cores.map(\.id))
            let unknownIDs = selectedIDs.subtracting(knownIDs)
            guard unknownIDs.isEmpty else {
                throw CoreToolError.build(
                    "Unknown core id: \(unknownIDs.sorted().joined(separator: ", "))."
                )
            }
        }

        let selected = manifest.cores.filter { core in
            core.status.participatesInBuild
                && (selectedIDs.isEmpty || selectedIDs.contains(core.id))
        }

        guard !selected.isEmpty else {
            throw CoreToolError.build("No buildable cores were selected.")
        }

        return selected.sorted { $0.id < $1.id }
    }

    private static func clone(
        _ core: CoreManifest.Core,
        into sourceDirectory: URL,
        manifestDirectory: URL
    ) throws {
        try run(
            "/usr/bin/git",
            arguments: ["init", "--quiet"],
            currentDirectory: sourceDirectory
        )
        try run(
            "/usr/bin/git",
            arguments: ["remote", "add", "origin", core.source.repository],
            currentDirectory: sourceDirectory
        )
        try run(
            "/usr/bin/git",
            arguments: [
                "-c",
                "protocol.version=2",
                "fetch",
                "--quiet",
                "--depth",
                "1",
                "origin",
                core.source.revision,
            ],
            currentDirectory: sourceDirectory
        )
        try run(
            "/usr/bin/git",
            arguments: ["checkout", "--quiet", "--detach", "FETCH_HEAD"],
            currentDirectory: sourceDirectory
        )

        let revision = try capture(
            "/usr/bin/git",
            arguments: ["rev-parse", "HEAD"],
            currentDirectory: sourceDirectory
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard revision == core.source.revision else {
            throw CoreToolError.build(
                "\(core.id) resolved to \(revision), not \(core.source.revision)."
            )
        }

        for patch in core.source.patches ?? [] {
            try run(
                "/usr/bin/git",
                arguments: [
                    "-c",
                    "protocol.version=2",
                    "fetch",
                    "--quiet",
                    "--depth",
                    "2",
                    "origin",
                    patch,
                ],
                currentDirectory: sourceDirectory
            )
            let resolvedPatch = try capture(
                "/usr/bin/git",
                arguments: ["rev-parse", "FETCH_HEAD"],
                currentDirectory: sourceDirectory
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard resolvedPatch == patch else {
                throw CoreToolError.build(
                    "\(core.id) patch resolved to \(resolvedPatch), not \(patch)."
                )
            }
            try run(
                "/usr/bin/git",
                arguments: ["cherry-pick", "--no-commit", patch],
                currentDirectory: sourceDirectory
            )
        }

        let submodules = core.source.submodules ?? []
        if !submodules.isEmpty {
            try run(
                "/usr/bin/git",
                arguments: [
                    "submodule",
                    "update",
                    "--init",
                    "--recursive",
                    "--depth",
                    "1",
                    "--",
                ] + submodules,
                currentDirectory: sourceDirectory
            )
        }

        for patch in core.source.localPatches ?? [] {
            let patchURL = manifestDirectory.appending(path: patch.path)
            guard FileManager.default.fileExists(atPath: patchURL.path) else {
                throw CoreToolError.build(
                    "\(core.id) is missing its declared local patch \(patch.path)."
                )
            }

            let actualDigest = try sha256(of: patchURL)
            guard actualDigest == patch.sha256 else {
                throw CoreToolError.build(
                    "\(core.id) local patch \(patch.path) has SHA-256 \(actualDigest), "
                        + "not \(patch.sha256)."
                )
            }

            try run(
                "/usr/bin/git",
                arguments: ["apply", "--check", patchURL.path],
                currentDirectory: sourceDirectory
            )
            try run(
                "/usr/bin/git",
                arguments: ["apply", "--whitespace=nowarn", patchURL.path],
                currentDirectory: sourceDirectory
            )
        }

    }

    private static func validateBinary(_ url: URL, coreID: String) throws {
        let architectures = try capture(
            "/usr/bin/lipo",
            arguments: ["-archs", url.path]
        )
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)

        guard architectures == ["arm64"] else {
            throw CoreToolError.build(
                "\(coreID) must contain only arm64; found "
                    + architectures.joined(separator: ", ")
            )
        }

        let symbols = try capture(
            "/usr/bin/nm",
            arguments: ["-gU", url.path]
        )
        let requiredSymbols = [
            "_retro_api_version",
            "_retro_init",
            "_retro_load_game",
            "_retro_run",
            "_retro_unload_game",
        ]
        let missingSymbols = requiredSymbols.filter { !symbols.contains($0) }

        guard missingSymbols.isEmpty else {
            throw CoreToolError.build(
                "\(coreID) is missing required libretro symbols: "
                    + missingSymbols.joined(separator: ", ")
            )
        }
    }

    private static func sign(_ url: URL, identity: String) throws {
        var arguments = ["--force", "--sign", identity]

        if identity == "-" {
            arguments.append("--timestamp=none")
        } else {
            arguments.append(contentsOf: ["--options", "runtime", "--timestamp"])
        }

        arguments.append(url.path)
        try run("/usr/bin/codesign", arguments: arguments)
    }

    private static func verifySignature(_ url: URL) throws {
        try run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--verbose=2", url.path]
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let output = try capture(
            "/usr/bin/shasum",
            arguments: ["-a", "256", url.path]
        )

        guard let digest = output.split(whereSeparator: \.isWhitespace).first,
              digest.count == 64
        else {
            throw CoreToolError.build(
                "Could not determine the SHA-256 for \(url.lastPathComponent)."
            )
        }

        return String(digest)
    }

    private static func requireEmptyDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CoreToolError.build(
                    "Output path is not a directory: \(url.path)"
                )
            }

            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else {
                throw CoreToolError.build(
                    "Output directory must be empty: \(url.path)"
                )
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    private static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> String {
        try execute(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            echoOutput: true
        )
    }

    private static func capture(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> String {
        try execute(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: [:],
            echoOutput: false
        )
    }

    private static func execute(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        echoOutput: Bool
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, new in new }
        )

        do {
            try process.run()
        } catch {
            throw CoreToolError.build(
                "Could not launch \(executable): \(error.localizedDescription)"
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        if echoOutput, !output.isEmpty {
            print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
        }

        guard process.terminationStatus == 0 else {
            let command = ([executable] + arguments)
                .map(shellEscaped)
                .joined(separator: " ")
            throw CoreToolError.commandFailed(
                command: command,
                status: process.terminationStatus,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }

    private static func shellEscaped(_ value: String) -> String {
        guard value.contains(where: \.isWhitespace) else {
            return value
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
