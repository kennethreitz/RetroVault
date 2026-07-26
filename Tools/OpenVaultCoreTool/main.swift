import Darwin
import Foundation

@main
enum OpenVaultCoreTool {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CoreToolError.usage(usage)
        }

        switch command {
        case "validate":
            guard arguments.count == 2 else {
                throw CoreToolError.usage(usage)
            }

            let manifestURL = URL(fileURLWithPath: arguments[1])
            let manifest = try ManifestLoader.load(from: manifestURL)
            try ManifestValidator.validate(manifest)
            let enabledCount = manifest.cores.count { $0.status.participatesInBuild }
            print(
                "Validated \(manifest.cores.count) core entries "
                    + "(\(enabledCount) buildable)."
            )

        case "build":
            let options = try parseBuildOptions(Array(arguments.dropFirst()))
            let manifest = try ManifestLoader.load(from: options.manifestURL)
            try ManifestValidator.validate(manifest)
            let receipt = try CoreBuilder.build(manifest: manifest, options: options)
            print(
                "Built \(receipt.cores.count) core artifact"
                    + (receipt.cores.count == 1 ? "." : "s.")
            )

        default:
            throw CoreToolError.usage("Unknown command \(command).\n\n\(usage)")
        }
    }

    private static func parseBuildOptions(
        _ arguments: [String]
    ) throws -> CoreBuildOptions {
        var manifestURL: URL?
        var outputDirectory: URL?
        var workDirectory: URL?
        var selectedCoreIDs = Set<String>()
        var signingIdentity = "-"
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--manifest", "--output", "--work", "--core", "--sign":
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw CoreToolError.usage(
                        "\(argument) requires a value.\n\n\(usage)"
                    )
                }

                let value = arguments[valueIndex]
                switch argument {
                case "--manifest":
                    manifestURL = URL(fileURLWithPath: value)
                case "--output":
                    outputDirectory = URL(fileURLWithPath: value)
                case "--work":
                    workDirectory = URL(fileURLWithPath: value)
                case "--core":
                    selectedCoreIDs.insert(value)
                case "--sign":
                    signingIdentity = value
                default:
                    break
                }
                index += 2

            default:
                throw CoreToolError.usage(
                    "Unknown build argument \(argument).\n\n\(usage)"
                )
            }
        }

        guard let manifestURL, let outputDirectory, let workDirectory else {
            throw CoreToolError.usage(
                "build requires --manifest, --output, and --work.\n\n\(usage)"
            )
        }

        guard !signingIdentity.isEmpty else {
            throw CoreToolError.usage("--sign cannot be empty.")
        }

        return CoreBuildOptions(
            manifestURL: manifestURL,
            outputDirectory: outputDirectory,
            workDirectory: workDirectory,
            selectedCoreIDs: selectedCoreIDs,
            signingIdentity: signingIdentity
        )
    }

    private static let usage = """
    Usage:
      OpenVaultCoreTool validate <manifest>
      OpenVaultCoreTool build --manifest <path> --output <directory> \
        --work <directory> [--core <id>]... [--sign <identity>]

    Use --sign - for ad-hoc development signing. Release artifacts must supply
    OpenVault's Developer ID Application identity.
    """
}
