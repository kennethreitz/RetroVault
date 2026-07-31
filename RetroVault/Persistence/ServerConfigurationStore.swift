import Foundation

protocol ServerConfigurationStoring: Sendable {
    func load() async throws -> RemoteServerConfiguration?
    func save(_ configuration: RemoteServerConfiguration) async throws
    func remove() async throws
}

actor UserDefaultsServerConfigurationStore: ServerConfigurationStoring {
    private let defaults: UserDefaults
    private let key = "remote-server-configuration"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> RemoteServerConfiguration? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try decoder.decode(RemoteServerConfiguration.self, from: data)
    }

    func save(_ configuration: RemoteServerConfiguration) throws {
        defaults.set(try encoder.encode(configuration), forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}
