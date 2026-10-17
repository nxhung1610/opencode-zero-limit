import Foundation

/// The token gate for Edge.
///
/// macOS exposes no usable TCP peer credentials — verified empirically on
/// this platform (`LOCAL_PEERPID` is `ENOPROTOOPT`, `LOCAL_PEERCRED` returns
/// success without writing the buffer, `LOCAL_PEEREPID` returns 0) — so
/// identity is a per-install random token. The proxy environment carries it
/// as userinfo (`http://<token>:@127.0.0.1:<port>`), which clients send as
/// `Proxy-Authorization: Basic`, with the token as either the username or the
/// password side; admin clients send `Authorization: Bearer <token>`.
enum EdgeAuth {
    static func isAuthorized(headers: [String: String], token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if let authorization = headers["authorization"], let bearer = bearerToken(authorization) {
            return constantTimeEquals(bearer, token)
        }
        if let proxyAuthorization = headers["proxy-authorization"],
           let credentials = basicCredentials(proxyAuthorization) {
            return constantTimeEquals(credentials.user, token)
                || constantTimeEquals(credentials.password, token)
        }
        return false
    }

    static func bearerToken(_ header: String) -> String? {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }

    static func basicCredentials(_ header: String) -> (user: String, password: String)? {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let data = Data(base64Encoded: String(parts[1])),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        guard let colon = decoded.firstIndex(of: ":") else { return (decoded, "") }
        return (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let bytesLHS = Array(lhs.utf8)
        let bytesRHS = Array(rhs.utf8)
        guard bytesLHS.count == bytesRHS.count else { return false }
        var difference: UInt8 = 0
        for (lhsByte, rhsByte) in zip(bytesLHS, bytesRHS) {
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}
