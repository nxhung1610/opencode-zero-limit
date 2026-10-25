import Foundation

/// One parsed request head (through the final blank line) arriving at Edge.
/// Pure parsing: no sockets, no policy — unit-testable in isolation.
struct EdgeHTTPRequest: Equatable {
    enum Kind: Equatable {
        case connect(host: String, port: UInt16)
        case forward(method: String, scheme: String, host: String, port: UInt16, path: String)
        case admin(method: String, path: String, query: [String: String])
        case invalid(reason: String)
    }

    var method: String
    var version: String
    var kind: Kind
    /// Header names lowercased; the first occurrence wins.
    var headers: [String: String]
    /// The raw head bytes, so forwarding can pass unmodified headers through.
    var rawHead: Data

    static func parse(head: Data) -> EdgeHTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts.count > 2 ? parts[2] : "HTTP/1.1"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if headers[name] == nil { headers[name] = value }
        }

        func make(_ kind: Kind) -> EdgeHTTPRequest {
            EdgeHTTPRequest(method: method, version: version, kind: kind, headers: headers, rawHead: head)
        }

        if target.lowercased().hasPrefix("/__relaydock/") {
            let components = URLComponents(string: "http://relaydock.local" + target)
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            return make(.admin(method: method, path: components?.path ?? target, query: query))
        }

        if method == "CONNECT" {
            guard let (host, port) = splitHostPort(target, defaultPort: nil) else {
                return make(.invalid(reason: "CONNECT requires a host:port target."))
            }
            return make(.connect(host: host, port: port))
        }

        if let components = URLComponents(string: target),
           let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let rawHost = components.host, !rawHost.isEmpty {
            if scheme == "https" {
                return make(.invalid(reason: "https targets must use CONNECT."))
            }
            guard let port = components.port.map({ UInt16(exactly: $0) }) ?? 80, port > 0 else {
                return make(.invalid(reason: "The request target carries an invalid port."))
            }
            // Keep the encoded form: `path`/`query` decode `%2F` into `/`,
            // which changes the resource the upstream sees. Foundation still
            // normalizes malformed escapes and raw characters, so an invalid
            // target is re-encoded rather than forwarded as a broken line.
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            let withQuery = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
            return make(.forward(method: method, scheme: scheme, host: rawHost, port: port, path: withQuery))
        }

        return make(.invalid(reason: "Unsupported request target."))
    }

    /// Splits `host:port` / `[v6]:port` / `host` (with a default port).
    static func splitHostPort(_ value: String, defaultPort: UInt16?) -> (host: String, port: UInt16)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.isEmpty { return defaultPort.map { (host, $0) } }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            let portText = value[value.index(after: colon)...]
            guard !host.isEmpty, let port = UInt16(portText), port > 0 else { return nil }
            return (host, port)
        }
        return defaultPort.map { (value, $0) }
    }

    /// The head to forward in absolute (proxy) form: the original head with
    /// client proxy headers stripped, so client-side proxy credentials never
    /// leak upstream, plus the upstream's own `Proxy-Authorization` when it
    /// carries one.
    func absoluteForwardHead(upstreamAuthorization: String?) -> Data {
        rewriteHead(line: nil, upstreamAuthorization: upstreamAuthorization)
    }

    /// The head to forward in origin form (direct dials and SOCKS tunnels).
    func originForwardHead(upstreamAuthorization: String?) -> Data {
        guard case .forward(_, _, _, _, let path) = kind else { return rawHead }
        return rewriteHead(line: "\(method) \(path) \(version)", upstreamAuthorization: upstreamAuthorization)
    }

    private func rewriteHead(line replacement: String?, upstreamAuthorization: String?) -> Data {
        guard let text = String(data: rawHead, encoding: .utf8) else { return rawHead }
        var lines = text.split(whereSeparator: \.isNewline).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        guard !lines.isEmpty else { return rawHead }
        if let replacement { lines[0] = replacement }
        var filtered: [String] = [lines[0]]
        for line in lines.dropFirst() {
            let name = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            // Client-supplied proxy credentials and connection-management
            // headers are hop-local; they must not travel to the upstream.
            if name == "proxy-authorization" || name == "proxy-connection" { continue }
            filtered.append(line)
        }
        var rebuilt = filtered.joined(separator: "\r\n") + "\r\n"
        if let upstreamAuthorization {
            rebuilt += "Proxy-Authorization: \(upstreamAuthorization)\r\n"
        }
        return Data((rebuilt + "\r\n").utf8)
    }
}
