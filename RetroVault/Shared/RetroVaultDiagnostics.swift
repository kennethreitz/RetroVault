import Foundation
import OSLog

/// Unified logging categories used throughout RetroVault.
enum RetroVaultLog {
    static let subsystem = "org.kennethreitz.RetroVault"

    static let application = Logger(subsystem: subsystem, category: "Application")
    static let connection = Logger(subsystem: subsystem, category: "Connection")
    static let library = Logger(subsystem: subsystem, category: "Library")
    static let network = Logger(subsystem: subsystem, category: "Networking")
    static let libretro = Logger(subsystem: subsystem, category: "Libretro")
    static let cemu = Logger(subsystem: subsystem, category: "Cemu")
}

enum RetroVaultDiagnosticLevel: Int, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case notice
    case error
    case fault

    var id: Self { self }

    var title: String {
        switch self {
        case .debug:
            "Debug"
        case .info:
            "Info"
        case .notice:
            "Notice"
        case .error:
            "Error"
        case .fault:
            "Fault"
        }
    }
}

struct RetroVaultDiagnosticEntry: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let level: RetroVaultDiagnosticLevel
    let category: String
    let message: String
}

/// Reads RetroVault entries directly from this process's macOS unified log.
enum RetroVaultDiagnostics {
    static func entries(
        since startDate: Date,
        limit: Int = 2_000
    ) async throws -> [RetroVaultDiagnosticEntry] {
        try await Task.detached(priority: .utility) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: startDate)
            let predicate = NSPredicate(
                format: "subsystem == %@",
                RetroVaultLog.subsystem
            )
            let entries = try store.getEntries(
                at: position,
                matching: predicate
            )

            var duplicateCounts: [String: Int] = [:]
            var results: [RetroVaultDiagnosticEntry] = []

            for case let entry as OSLogEntryLog in entries {
                let level = diagnosticLevel(entry.level)
                let baseID = [
                    entry.date.timeIntervalSinceReferenceDate.description,
                    level.title,
                    entry.category,
                    entry.composedMessage,
                ].joined(separator: "|")
                let duplicateCount = duplicateCounts[baseID, default: 0]
                duplicateCounts[baseID] = duplicateCount + 1

                results.append(
                    RetroVaultDiagnosticEntry(
                        id: "\(baseID)|\(duplicateCount)",
                        date: entry.date,
                        level: level,
                        category: entry.category,
                        message: entry.composedMessage
                    )
                )
            }

            return Array(results.suffix(max(1, limit)))
        }.value
    }

    private static func diagnosticLevel(
        _ level: OSLogEntryLog.Level
    ) -> RetroVaultDiagnosticLevel {
        switch level {
        case .debug, .undefined:
            .debug
        case .info:
            .info
        case .notice:
            .notice
        case .error:
            .error
        case .fault:
            .fault
        @unknown default:
            .debug
        }
    }
}
