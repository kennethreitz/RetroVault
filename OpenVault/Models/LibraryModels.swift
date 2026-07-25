import Foundation

/// A game system exposed by the connected RomM library.
struct LibrarySystem: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let gameCount: Int
}

/// A regular or smart collection exposed by RomM.
struct LibraryCollection: Identifiable, Hashable, Sendable {
    enum ID: Hashable, Sendable {
        case regular(Int)
        case smart(Int)
    }

    let id: ID
    let name: String
    let gameCount: Int
}

/// The subset of RomM game metadata needed to render the library grid.
struct GameSummary: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let systemID: Int
    let systemName: String
    let coverURL: URL?
}

/// A page of games returned by RomM.
struct GamePage: Equatable, Sendable {
    let games: [GameSummary]
    let total: Int
    let limit: Int
    let offset: Int

    var hasMore: Bool {
        offset + games.count < total
    }
}

/// A server-side filter for the shared game grid.
enum LibraryFilter: Equatable, Sendable {
    case allGames
    case system(Int)
    case collection(LibraryCollection.ID)
}
