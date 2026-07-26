import Foundation

/// A validated and normalized RomM server URL.
struct ServerURL: Codable, Equatable, Hashable, Sendable {
    let value: URL

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw ServerURLError.invalid
        }

        if scheme == "http", !Self.isLocalHost(host) {
            throw ServerURLError.insecureRemoteServer
        }

        components.scheme = scheme

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        if path.hasSuffix("/api") {
            path.removeLast(4)
        }
        components.path = path

        guard let normalizedURL = components.url else {
            throw ServerURLError.invalid
        }

        value = normalizedURL
    }

    func endpoint(_ path: String) -> URL {
        let component = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.appending(path: component)
    }

    /// The signed-in RomM page where a user creates and pairs client API tokens.
    var clientTokenManagementURL: URL {
        endpoint("client-api-tokens")
    }

    func resourceURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: value)?.absoluteURL
        }

        let directoryURL = value.appending(path: "")
        return URL(string: trimmed, relativeTo: directoryURL)?.absoluteURL
    }

    func hasSameOrigin(as url: URL) -> Bool {
        value.scheme?.lowercased() == url.scheme?.lowercased()
            && value.host?.lowercased() == url.host?.lowercased()
            && effectivePort(of: value) == effectivePort(of: url)
    }

    private func effectivePort(of url: URL) -> Int? {
        if let port = url.port {
            return port
        }

        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()

        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return host.hasPrefix("fe80:")
                || host.hasPrefix("fc")
                || host.hasPrefix("fd")
        }

        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

enum ServerURLError: LocalizedError, Equatable {
    case invalid
    case insecureRemoteServer

    var errorDescription: String? {
        switch self {
        case .invalid:
            "Enter a complete HTTP or HTTPS RomM server URL."
        case .insecureRemoteServer:
            "Remote RomM servers must use HTTPS. HTTP is allowed only for local servers."
        }
    }
}
