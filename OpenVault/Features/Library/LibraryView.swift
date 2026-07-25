import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryModel
    @State private var searchText = ""
    @State private var showsEmptySystems = false

    init(session: ServerSession, service: any LibraryServing) {
        _model = State(
            initialValue: LibraryModel(
                session: session,
                service: service
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                Label("All Games", systemImage: "rectangle.stack")
                    .badge(model.allGameCount)
                    .tag(LibrarySelection.allGames)

                Section("Systems") {
                    ForEach(populatedSystems) { system in
                        Label(system.name, systemImage: "gamecontroller")
                            .badge(system.gameCount)
                            .tag(LibrarySelection.system(system.id))
                    }

                    if !emptySystems.isEmpty {
                        DisclosureGroup(isExpanded: $showsEmptySystems) {
                            ForEach(emptySystems) { system in
                                Label(system.name, systemImage: "tray")
                                    .badge(system.gameCount)
                                    .tag(LibrarySelection.system(system.id))
                            }
                        } label: {
                            Label(
                                "Empty Systems",
                                systemImage: "tray.2"
                            )
                            .badge(emptySystems.count)
                        }
                    }
                }

                Section("Collections") {
                    if model.collections.isEmpty, !model.isLoading {
                        Text("No Collections")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.collections) { collection in
                            Label(collection.name, systemImage: collection.systemImage)
                                .badge(collection.gameCount)
                                .tag(LibrarySelection.collection(collection.id))
                        }
                    }
                }
            }
            .navigationTitle("OpenVault")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            LibraryGridView(model: model)
                .navigationTitle(model.title)
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task {
                                await model.refresh()
                            }
                        } label: {
                            Label("Refresh Library", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isLoading)
                    }

                    ToolbarItem {
                        Menu {
                            Toggle(
                                "Hide Games Without Artwork",
                                isOn: hidesGamesWithoutArtworkBinding
                            )
                        } label: {
                            Label(
                                "Library Filters",
                                systemImage: model.hidesGamesWithoutArtwork
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle"
                            )
                        }
                    }

                    if shouldOfferAllSystemsSearch {
                        ToolbarItem {
                            Toggle(
                                "Search All Systems",
                                isOn: searchesAllSystemsBinding
                            )
                            .toggleStyle(.checkbox)
                        }
                    }
                }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search Games"
        )
        .task {
            await model.load()
        }
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else {
                    return
                }
                await model.search(for: searchText)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private var populatedSystems: [LibrarySystem] {
        model.systems.filter { $0.gameCount > 0 }
    }

    private var emptySystems: [LibrarySystem] {
        model.systems.filter { $0.gameCount == 0 }
    }

    private var shouldOfferAllSystemsSearch: Bool {
        !model.searchTerm.isEmpty && model.selection != .allGames
    }

    private var hidesGamesWithoutArtworkBinding: Binding<Bool> {
        Binding(
            get: { model.hidesGamesWithoutArtwork },
            set: { model.setHidesGamesWithoutArtwork($0) }
        )
    }

    private var searchesAllSystemsBinding: Binding<Bool> {
        Binding(
            get: { model.searchesAllSystems },
            set: { enabled in
                Task {
                    await model.setSearchesAllSystems(enabled)
                }
            }
        )
    }

    private var selectionBinding: Binding<LibrarySelection> {
        Binding(
            get: { model.selection },
            set: { selection in
                guard model.selection != selection else {
                    return
                }

                model.selection = selection
                Task {
                    await model.reloadGames()
                }
            }
        )
    }
}

private struct LibraryGridView: View {
    let model: LibraryModel

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 22, alignment: .top),
    ]

    var body: some View {
        Group {
            if model.isLoading, model.games.isEmpty {
                ProgressView("Loading \(model.title)…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage, model.games.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.retry()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if model.games.isEmpty {
                if model.searchTerm.isEmpty {
                    ContentUnavailableView {
                        Label("No Games", systemImage: "rectangle.stack.badge.minus")
                    } description: {
                        Text("RomM did not return any games for \(model.title).")
                    }
                } else {
                    ContentUnavailableView.search(text: model.searchTerm)
                }
            } else if model.displayedGames.isEmpty {
                ContentUnavailableView {
                    Label("No Games with Artwork", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("No artwork was found in the loaded results.")
                } actions: {
                    if model.hasMoreGames {
                        Button("Search More Results") {
                            Task {
                                await model.loadMore()
                            }
                        }
                    }

                    Button("Show Games Without Artwork") {
                        model.setHidesGamesWithoutArtwork(false)
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(model.displayedGames) { game in
                            GameCard(
                                game: game,
                                session: model.session,
                                service: model.service
                            )
                            .task {
                                await model.loadMoreIfNeeded(near: game)
                            }
                        }
                    }

                    paginationFooter
                        .padding(.top, 20)
                }
                .contentMargins(28, for: .scrollContent)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !model.displayedGames.isEmpty {
                Text(resultCountLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var resultCountLabel: String {
        if model.hidesGamesWithoutArtwork {
            return "\(model.displayedGames.count.formatted()) shown with artwork"
        }

        if model.searchTerm.isEmpty {
            return "\(model.totalGameCount.formatted()) games"
        } else {
            return "\(model.totalGameCount.formatted()) results"
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding()
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 10) {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Try Again") {
                    Task {
                        await model.retry()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

private struct GameCard: View {
    let game: GameSummary
    let session: ServerSession
    let service: any LibraryServing

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GameCoverView(
                game: game,
                session: session,
                service: service
            )

            Text(game.name)
                .font(.headline)
                .lineLimit(2)

            Text(game.systemName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.name), \(game.systemName)")
    }
}

private extension LibraryCollection {
    var systemImage: String {
        switch id {
        case .regular:
            "square.stack"
        case .smart:
            "line.3.horizontal.decrease.circle"
        }
    }
}
