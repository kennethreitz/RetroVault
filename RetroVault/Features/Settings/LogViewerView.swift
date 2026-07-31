import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LogViewerModel {
    private(set) var entries: [RetroVaultDiagnosticEntry] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    var searchText = ""
    var minimumLevel = RetroVaultDiagnosticLevel.debug
    var isPaused = false

    private var startDate = Date.now.addingTimeInterval(-5 * 60)

    var filteredEntries: [RetroVaultDiagnosticEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return entries.filter { entry in
            guard entry.level.rawValue >= minimumLevel.rawValue else {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            return entry.category.localizedCaseInsensitiveContains(query)
                || entry.level.title.localizedCaseInsensitiveContains(query)
                || entry.message.localizedCaseInsensitiveContains(query)
        }
    }

    func run() async {
        RetroVaultLog.application.notice("Opened the native log viewer")

        while !Task.isCancelled {
            if !isPaused {
                await refresh()
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            entries = try await RetroVaultDiagnostics.entries(since: startDate)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            RetroVaultLog.application.error(
                "Could not read the unified log: \(error.localizedDescription)"
            )
        }
    }

    func clearView() {
        startDate = .now
        entries = []
        errorMessage = nil
        RetroVaultLog.application.notice("Cleared the native log viewer")
    }

    func text(for selectedIDs: Set<RetroVaultDiagnosticEntry.ID>) -> String {
        let source = selectedIDs.isEmpty
            ? filteredEntries
            : filteredEntries.filter { selectedIDs.contains($0.id) }

        return source.map { entry in
            let timestamp = entry.date.formatted(
                .iso8601
                    .year()
                    .month()
                    .day()
                    .time(includingFractionalSeconds: true)
            )
            return "\(timestamp) [\(entry.level.title)] [\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

struct LogViewerView: View {
    @State private var model = LogViewerModel()
    @State private var selection: Set<RetroVaultDiagnosticEntry.ID> = []

    var body: some View {
        Table(model.filteredEntries, selection: $selection) {
            TableColumn("Time") { entry in
                Text(
                    entry.date.formatted(
                        date: .omitted,
                        time: .standard
                    )
                )
                .monospacedDigit()
            }
            .width(min: 90, ideal: 105, max: 125)

            TableColumn("Level") { entry in
                Text(entry.level.title)
                    .fontWeight(.medium)
                    .foregroundStyle(color(for: entry.level))
            }
            .width(min: 60, ideal: 72, max: 90)

            TableColumn("Category") { entry in
                Text(entry.category)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120, max: 170)

            TableColumn("Message") { entry in
                Text(entry.message)
                    .textSelection(.enabled)
            }
            .width(min: 320, ideal: 620)
        }
        .overlay {
            if model.filteredEntries.isEmpty {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)

                Text(model.isPaused ? "Paused" : "Live")
                Text("•")
                Text(
                    "\(model.filteredEntries.count.formatted()) of \(model.entries.count.formatted()) entries"
                )

                Spacer()

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .searchable(text: $model.searchText, prompt: "Filter Logs")
        .toolbar {
            ToolbarItemGroup {
                Picker("Minimum Level", selection: $model.minimumLevel) {
                    ForEach(RetroVaultDiagnosticLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(
                        model.isPaused ? "Resume" : "Pause",
                        systemImage: model.isPaused ? "play.fill" : "pause.fill"
                    )
                }

                Button {
                    Task {
                        await model.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    copyVisibleEntries()
                } label: {
                    Label(
                        selection.isEmpty ? "Copy Visible" : "Copy Selected",
                        systemImage: "doc.on.doc"
                    )
                }
                .disabled(model.filteredEntries.isEmpty)

                Button {
                    selection.removeAll()
                    model.clearView()
                } label: {
                    Label("Clear View", systemImage: "trash")
                }
                .disabled(model.entries.isEmpty)
            }
        }
        .task {
            await model.run()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn’t Read Logs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task {
                        await model.refresh()
                    }
                }
            }
        } else if model.isRefreshing {
            ProgressView("Loading RetroVault logs…")
                .controlSize(.large)
        } else {
            ContentUnavailableView(
                "No Matching Logs",
                systemImage: "text.alignleft",
                description: Text("Use RetroVault or change the current filters.")
            )
        }
    }

    private func copyVisibleEntries() {
        let text = model.text(for: selection)
        guard !text.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func color(for level: RetroVaultDiagnosticLevel) -> Color {
        switch level {
        case .debug:
            .secondary
        case .info:
            .blue
        case .notice:
            .primary
        case .error:
            .orange
        case .fault:
            .red
        }
    }
}
