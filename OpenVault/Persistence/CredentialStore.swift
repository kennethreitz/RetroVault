import Foundation

protocol CredentialStoring: Sendable {
    func loadToken() async throws -> ClientToken?
    func save(_ token: ClientToken) async throws
    func removeToken() async throws
}
