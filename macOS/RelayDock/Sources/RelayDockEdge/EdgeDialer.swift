import Darwin
import Foundation

struct EdgeProxyCredentials: Equatable, Sendable {
    var user: String
    var password: String
}

/// A dialed tunnel: the raw socket plus bytes the far end already sent (for
/// example, a TLS server that spoke before reading, buffered behind the
/// CONNECT reply).
struct EdgeUpstreamTunnel {
    let socket: EdgeSocket
    let initialData: Data
}

/// A raw connection to the upstream proxy itself, before any handshake —
/// used for absolute-form forwarding through plain HTTP(S) proxies.
struct EdgeProxyHop {
    let socket: EdgeSocket
    let credentials: EdgeProxyCredentials?
}

/// Byte-level builders for the upstream protocols. Pure functions so the
/// handshakes are unit-testable without sockets.
enum EdgeSocks {
    static func socks5Greeting(hasCredentials: Bool) -> Data {
        hasCredentials ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00])
    }

    static func socks5AuthRequest(user: String, password: String) -> Data {
        var data = Data([0x01])
        let userBytes = Array(user.utf8.prefix(255))
        let passwordBytes = Array(password.utf8.prefix(255))
        data.append(UInt8(userBytes.count))
        data.append(contentsOf: userBytes)
        data.append(UInt8(passwordBytes.count))
        data.append(contentsOf: passwordBytes)
        return data
    }

    /// nil when `socks5` (local DNS) cannot resolve the host.
    static func socks5Connect(host: String, port: UInt16, remoteDNS: Bool) -> Data? {
        var data = Data([0x05, 0x01, 0x00])
        if let ipv4 = ipv4Bytes(host) {
            data.append(0x01)
            data.append(ipv4)
        } else if let ipv6 = ipv6Bytes(host) {
            data.append(0x04)
            data.append(ipv6)
        } else if remoteDNS {
            let hostBytes = Array(host.utf8.prefix(255))
            data.append(0x03)
            data.append(UInt8(hostBytes.count))
            data.append(contentsOf: hostBytes)
        } else if let resolved = resolveIPv4(host) {
            data.append(0x01)
            data.append(resolved)
        } else {
            return nil
        }
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        return data
    }

    /// nil when `socks4` (local DNS) cannot resolve the host.
    static func socks4Connect(host: String, port: UInt16, userID: String, remoteDNS: Bool) -> Data? {
        var data = Data([0x04, 0x01])
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        var hostnameSuffix: String?
        if let ipv4 = ipv4Bytes(host) {
            data.append(ipv4)
        } else if remoteDNS {
            // SOCKS4a: the invalid address 0.0.0.x signals "hostname follows".
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            hostnameSuffix = host
        } else if let resolved = resolveIPv4(host) {
            data.append(resolved)
        } else {
            return nil
        }
        data.append(contentsOf: Array(userID.utf8))
        data.append(0)
        if let hostnameSuffix {
            data.append(contentsOf: Array(hostnameSuffix.utf8))
            data.append(0)
        }
        return data
    }

    static func ipv4Bytes(_ host: String) -> Data? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address.s_addr) { Data($0) }
    }

    static func ipv6Bytes(_ host: String) -> Data? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Data($0) }
    }

    static func isIPAddress(_ host: String) -> Bool {
        ipv4Bytes(host) != nil || ipv6Bytes(host) != nil
    }

    static func resolveIPv4(_ host: String) -> Data? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let list = result else { return nil }
        defer { freeaddrinfo(list) }
        var pointer: UnsafeMutablePointer<addrinfo>? = list
        while let current = pointer {
            if let address = current.pointee.ai_addr {
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                return withUnsafeBytes(of: ipv4.s_addr) { Data($0) }
            }
            pointer = current.pointee.ai_next
        }
        return nil
    }

    static func formatAuthority(_ host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func basicAuthorization(_ credentials: EdgeProxyCredentials) -> String {
        let raw = "\(credentials.user):\(credentials.password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }
}

/// Dials the target directly or through a concrete upstream URL, completing
/// the upstream handshake so callers only ever relay raw bytes.
enum EdgeDialer {
    static func openDirect(toHost host: String, port: UInt16) async throws -> EdgeUpstreamTunnel {
        let socket = EdgeSocket(host: host, port: port)
        try await socket.awaitReady(timeout: 8)
        return EdgeUpstreamTunnel(socket: socket, initialData: Data())
    }

    static func openTunnel(
        through upstreamURL: String,
        toHost host: String,
        port: UInt16,
        reusing warm: EdgeSocket? = nil
    ) async throws -> EdgeUpstreamTunnel {
        guard let components = URLComponents(string: upstreamURL),
              let scheme = components.scheme?.lowercased(),
              let proxyHost = components.host, !proxyHost.isEmpty,
              let rawPort = components.port,
              let proxyPort = UInt16(exactly: rawPort) else {
            throw EdgeSocketError.unsupported("Unsupported upstream URL.")
        }
        let credentials = credentials(from: components)
        switch scheme {
        case "http", "https":
            return try await httpConnect(
                proxyHost: proxyHost, proxyPort: proxyPort, tls: scheme == "https",
                credentials: credentials, host: host, port: port, reusing: warm
            )
        case "socks5", "socks5h":
            return try await socks5Connect(
                proxyHost: proxyHost, proxyPort: proxyPort, remoteDNS: scheme == "socks5h",
                credentials: credentials, host: host, port: port, reusing: warm
            )
        case "socks4", "socks4a":
            return try await socks4Connect(
                proxyHost: proxyHost, proxyPort: proxyPort, remoteDNS: scheme == "socks4a",
                credentials: credentials, host: host, port: port, reusing: warm
            )
        default:
            throw EdgeSocketError.unsupported("Unsupported upstream scheme \(scheme).")
        }
    }

    /// Opens a raw connection to the upstream proxy itself (for absolute-form
    /// forwarding): no CONNECT, no handshake yet.
    static func openProxySocket(through upstreamURL: String, reusing warm: EdgeSocket? = nil) async throws -> EdgeProxyHop {
        guard let components = URLComponents(string: upstreamURL),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let proxyHost = components.host, !proxyHost.isEmpty,
              let rawPort = components.port,
              let proxyPort = UInt16(exactly: rawPort) else {
            throw EdgeSocketError.unsupported("Unsupported upstream URL.")
        }
        let socket = warm ?? EdgeSocket(
            host: proxyHost, port: proxyPort, tls: scheme == "https",
            serverName: scheme == "https" ? proxyHost : nil
        )
        try await socket.awaitReady(timeout: 8)
        return EdgeProxyHop(socket: socket, credentials: credentials(from: components))
    }

    static func scheme(of upstreamURL: String) -> String? {
        URLComponents(string: upstreamURL)?.scheme?.lowercased()
    }

    static func credentials(from components: URLComponents) -> EdgeProxyCredentials? {
        guard let user = components.user, !user.isEmpty else { return nil }
        let password = components.password ?? ""
        return EdgeProxyCredentials(
            user: user.removingPercentEncoding ?? user,
            password: password.removingPercentEncoding ?? password
        )
    }

    private static func httpConnect(
        proxyHost: String,
        proxyPort: UInt16,
        tls: Bool,
        credentials: EdgeProxyCredentials?,
        host: String,
        port: UInt16,
        reusing warm: EdgeSocket? = nil
    ) async throws -> EdgeUpstreamTunnel {
        let socket = warm ?? EdgeSocket(host: proxyHost, port: proxyPort, tls: tls, serverName: tls ? proxyHost : nil)
        try await socket.awaitReady(timeout: 8)
        let authority = EdgeSocks.formatAuthority(host, port: port)
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if let credentials {
            request += "Proxy-Authorization: \(EdgeSocks.basicAuthorization(credentials))\r\n"
        }
        request += "Proxy-Connection: keep-alive\r\n\r\n"
        try await socket.send(Data(request.utf8))
        let (head, rest, complete) = try await socket.receiveUntilHead()
        if complete && head.isEmpty { throw EdgeSocketError.closed }
        let status = statusCode(fromHead: head)
        guard let status, (200..<300).contains(status) else {
            throw EdgeSocketError.handshakeFailed("The upstream proxy rejected CONNECT (HTTP \(status.map(String.init) ?? "?")).")
        }
        return EdgeUpstreamTunnel(socket: socket, initialData: rest)
    }

    private static func socks5Connect(
        proxyHost: String,
        proxyPort: UInt16,
        remoteDNS: Bool,
        credentials: EdgeProxyCredentials?,
        host: String,
        port: UInt16,
        reusing warm: EdgeSocket? = nil
    ) async throws -> EdgeUpstreamTunnel {
        let socket = warm ?? EdgeSocket(host: proxyHost, port: proxyPort)
        try await socket.awaitReady(timeout: 8)
        try await socket.send(EdgeSocks.socks5Greeting(hasCredentials: credentials != nil))
        let choice = try await socket.receiveExactly(2)
        guard choice[0] == 0x05 else { throw EdgeSocketError.handshakeFailed("SOCKS5: bad version byte.") }
        switch choice[1] {
        case 0x00:
            break
        case 0x02:
            guard let credentials else {
                throw EdgeSocketError.handshakeFailed("SOCKS5: the proxy requires authentication.")
            }
            try await socket.send(EdgeSocks.socks5AuthRequest(user: credentials.user, password: credentials.password))
            let authReply = try await socket.receiveExactly(2)
            guard authReply[1] == 0x00 else {
                throw EdgeSocketError.handshakeFailed("SOCKS5: authentication was rejected.")
            }
        case 0xFF:
            throw EdgeSocketError.handshakeFailed("SOCKS5: no acceptable authentication method.")
        default:
            throw EdgeSocketError.handshakeFailed("SOCKS5: unsupported authentication method \(choice[1]).")
        }
        guard let connectRequest = EdgeSocks.socks5Connect(host: host, port: port, remoteDNS: remoteDNS) else {
            throw EdgeSocketError.handshakeFailed("SOCKS5: cannot resolve \(host) locally.")
        }
        try await socket.send(connectRequest)
        let replyHead = try await socket.receiveExactly(4)
        guard replyHead[0] == 0x05 else { throw EdgeSocketError.handshakeFailed("SOCKS5: bad reply version.") }
        guard replyHead[1] == 0x00 else {
            throw EdgeSocketError.handshakeFailed("SOCKS5: connect failed (code \(replyHead[1])).")
        }
        switch replyHead[3] {
        case 0x01: _ = try await socket.receiveExactly(6)
        case 0x04: _ = try await socket.receiveExactly(18)
        case 0x03:
            let length = (try await socket.receiveExactly(1)).first ?? 0
            _ = try await socket.receiveExactly(Int(length) + 2)
        default:
            throw EdgeSocketError.handshakeFailed("SOCKS5: bad reply address type.")
        }
        return EdgeUpstreamTunnel(socket: socket, initialData: Data())
    }

    private static func socks4Connect(
        proxyHost: String,
        proxyPort: UInt16,
        remoteDNS: Bool,
        credentials: EdgeProxyCredentials?,
        host: String,
        port: UInt16,
        reusing warm: EdgeSocket? = nil
    ) async throws -> EdgeUpstreamTunnel {
        let socket = warm ?? EdgeSocket(host: proxyHost, port: proxyPort)
        try await socket.awaitReady(timeout: 8)
        guard let request = EdgeSocks.socks4Connect(host: host, port: port, userID: credentials?.user ?? "", remoteDNS: remoteDNS) else {
            throw EdgeSocketError.handshakeFailed("SOCKS4: cannot resolve \(host) locally.")
        }
        try await socket.send(request)
        let reply = try await socket.receiveExactly(8)
        guard reply[0] == 0x00, reply[1] == 0x5A else {
            throw EdgeSocketError.handshakeFailed("SOCKS4: connect failed (code \(reply[1])).")
        }
        return EdgeUpstreamTunnel(socket: socket, initialData: Data())
    }

    private static func statusCode(fromHead head: Data) -> Int? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}
