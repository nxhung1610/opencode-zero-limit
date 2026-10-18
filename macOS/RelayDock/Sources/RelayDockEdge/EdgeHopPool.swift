import Foundation

/// Keying and dial planning for the warm hop pool (P3 upstream pooling):
/// Edge keeps one pre-dialed TCP/TLS socket to the current upstream proxy so
/// a new client connection skips the transport handshake. Pooled sockets
/// never carry application bytes — credentials are sent inside CONNECT or the
/// forwarded request, never during the TCP/TLS handshake — so reuse cannot
/// leak state between clients, and a stale socket fails exactly like a failed
/// cold dial (the dial-retry contract handles both).
enum EdgeHopPool {
    struct Target: Equatable {
        var host: String
        var port: UInt16
        var tls: Bool
    }

    /// The pre-dialable transport for an upstream proxy URL. Every supported
    /// scheme is pre-dialable, so only malformed URLs return nil.
    static func dialTarget(for upstreamURL: String) -> Target? {
        guard let components = URLComponents(string: upstreamURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h", "socks4", "socks4a"].contains(scheme),
              let host = components.host, !host.isEmpty,
              let rawPort = components.port,
              let port = UInt16(exactly: rawPort) else { return nil }
        return Target(host: host, port: port, tls: scheme == "https")
    }

    /// Pool key: transport only — credentials never enter the key because a
    /// pooled socket carries no application bytes.
    static func key(for upstreamURL: String) -> String? {
        guard let target = dialTarget(for: upstreamURL) else { return nil }
        return "\(target.tls ? "tls" : "tcp")://\(target.host):\(target.port)"
    }
}
