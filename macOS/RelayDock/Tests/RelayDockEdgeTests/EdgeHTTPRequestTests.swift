import Foundation
import Testing
@testable import RelayDockEdge

struct EdgeHTTPRequestTests {
    private func parse(_ text: String) -> EdgeHTTPRequest? {
        EdgeHTTPRequest.parse(head: Data(text.utf8))
    }

    @Test func parsesConnectTargets() throws {
        let request = try #require(parse("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"))
        #expect(request.method == "CONNECT")
        #expect(request.kind == .connect(host: "example.com", port: 443))
    }

    @Test func parsesBracketIPv6ConnectTargets() throws {
        let request = try #require(parse("CONNECT [2606:4700::1111]:8443 HTTP/1.1\r\n\r\n"))
        #expect(request.kind == .connect(host: "2606:4700::1111", port: 8443))
    }

    @Test func rejectsConnectWithoutAPort() throws {
        let request = try #require(parse("CONNECT example.com HTTP/1.1\r\n\r\n"))
        guard case .invalid = request.kind else {
            Issue.record("CONNECT without a port must be rejected")
            return
        }
    }

    @Test func rejectsConnectToPortZero() throws {
        for target in ["example.com:0", "[::1]:0"] {
            let request = try #require(parse("CONNECT \(target) HTTP/1.1\r\n\r\n"))
            guard case .invalid = request.kind else {
                Issue.record("CONNECT \(target) must be rejected")
                return
            }
        }
    }

    @Test func parsesAbsoluteFormForwardTargets() throws {
        let request = try #require(parse("GET http://example.com:8080/a?b=c HTTP/1.1\r\nHost: example.com\r\n\r\n"))
        #expect(request.kind == .forward(method: "GET", scheme: "http", host: "example.com", port: 8080, path: "/a?b=c"))
    }

    @Test func defaultsPlainHTTPPortTo80() throws {
        let request = try #require(parse("GET http://example.com/ HTTP/1.1\r\n\r\n"))
        #expect(request.kind == .forward(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/"))
    }

    @Test func preservesPercentEncodedForwardTargets() throws {
        let request = try #require(parse(
            "GET http://example.com/a%2Fb/%20c?q=x%2Fy&r=1%2B2&s=a+b HTTP/1.1\r\n\r\n"
        ))
        #expect(request.kind == .forward(
            method: "GET",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: "/a%2Fb/%20c?q=x%2Fy&r=1%2B2&s=a+b"
        ))
        let head = String(data: request.originForwardHead(upstreamAuthorization: nil), encoding: .utf8) ?? ""
        #expect(head.hasPrefix("GET /a%2Fb/%20c?q=x%2Fy&r=1%2B2&s=a+b HTTP/1.1\r\n"))
    }

    @Test func keepsEmptyPathsAndBareQuestionMarksStable() throws {
        let bareHost = try #require(parse("GET http://example.com HTTP/1.1\r\n\r\n"))
        #expect(bareHost.kind == .forward(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/"))

        let emptyQuery = try #require(parse("GET http://example.com/a? HTTP/1.1\r\n\r\n"))
        #expect(emptyQuery.kind == .forward(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/a?"))
    }

    @Test func malformedPercentEscapesAreReencodedNotForwardedRaw() throws {
        let request = try #require(parse("GET http://example.com/100% HTTP/1.1\r\n\r\n"))
        guard case .forward(_, _, _, _, let path) = request.kind else {
            Issue.record("a malformed escape must still produce a forward target")
            return
        }
        #expect(path == "/100%25")
    }

    @Test func rejectsAbsoluteHTTPSWithoutConnect() throws {
        let request = try #require(parse("GET https://example.com/ HTTP/1.1\r\n\r\n"))
        guard case .invalid = request.kind else {
            Issue.record("absolute https must be rejected in favor of CONNECT")
            return
        }
    }

    @Test func parsesAdminRequestsWithQuery() throws {
        let request = try #require(parse("GET /__relaydock/check?entry=px_1&scope=x HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n"))
        #expect(request.kind == .admin(method: "GET", path: "/__relaydock/check", query: ["entry": "px_1", "scope": "x"]))
        #expect(request.headers["authorization"] == "Bearer abc")
    }

    @Test func parsesFreeUsageLimitReportsAsAdminRequests() throws {
        let request = try #require(parse(
            "POST /__relaydock/free-usage-limit?retryAfterMs=34033000&entryID=px_a HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        ))
        #expect(request.kind == .admin(
            method: "POST",
            path: "/__relaydock/free-usage-limit",
            query: ["retryAfterMs": "34033000", "entryID": "px_a"]
        ))
    }

    @Test func lowercasesHeaderNamesAndKeepsFirstOccurrence() throws {
        let request = try #require(parse("CONNECT a:1 HTTP/1.1\r\nX-Test: one\r\nx-test: two\r\n\r\n"))
        #expect(request.headers["x-test"] == "one")
    }

    @Test func toleratesBareLineFeeds() throws {
        let request = try #require(parse("CONNECT a.example:443 HTTP/1.1\nHost: a.example\n\n"))
        #expect(request.kind == .connect(host: "a.example", port: 443))
    }

    @Test func rejectsGarbage() {
        #expect(parse("") == nil)
        #expect(parse("ONLYONEWORD\r\n\r\n") == nil)
        let request = parse("GET /relative/path HTTP/1.1\r\n\r\n")
        guard case .invalid = request?.kind else {
            Issue.record("relative targets outside the admin namespace must be invalid")
            return
        }
    }

    @Test func splitsHostPortForms() {
        #expect(EdgeHTTPRequest.splitHostPort("example.com:443", defaultPort: nil)?.host == "example.com")
        #expect(EdgeHTTPRequest.splitHostPort("example.com:443", defaultPort: nil)?.port == 443)
        #expect(EdgeHTTPRequest.splitHostPort("example.com", defaultPort: 80)?.port == 80)
        #expect(EdgeHTTPRequest.splitHostPort("[::1]:8443", defaultPort: nil)?.host == "::1")
        #expect(EdgeHTTPRequest.splitHostPort("[::1]:8443", defaultPort: nil)?.port == 8443)
        // Unbracketed IPv6 targets are out of spec but still split at the last
        // colon, so the port is never mistaken for a group.
        #expect(EdgeHTTPRequest.splitHostPort("2606:4700::1111:443", defaultPort: nil)?.host == "2606:4700::1111")
        #expect(EdgeHTTPRequest.splitHostPort("2606:4700::1111:443", defaultPort: nil)?.port == 443)
        #expect(EdgeHTTPRequest.splitHostPort(":443", defaultPort: nil) == nil)
        #expect(EdgeHTTPRequest.splitHostPort("example.com:0", defaultPort: nil) == nil)
        #expect(EdgeHTTPRequest.splitHostPort("[::1]:0", defaultPort: nil) == nil)
    }

    @Test func originForwardHeadRewritesTheRequestLineAndDropsProxyHeaders() throws {
        let request = try #require(parse(
            "GET http://example.com/a HTTP/1.1\r\n"
            + "Host: example.com\r\n"
            + "Proxy-Authorization: Basic client-proxy-secret\r\n"
            + "Proxy-Connection: keep-alive\r\n"
            + "User-Agent: test\r\n\r\n"
        ))
        let head = String(data: request.originForwardHead(upstreamAuthorization: nil), encoding: .utf8) ?? ""
        #expect(head.hasPrefix("GET /a HTTP/1.1\r\n"))
        #expect(!head.lowercased().contains("proxy-authorization"))
        #expect(!head.lowercased().contains("proxy-connection"))
        #expect(head.contains("User-Agent: test\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test func absoluteForwardHeadKeepsTheAbsoluteTargetAndInjectsUpstreamAuth() throws {
        let request = try #require(parse(
            "GET http://example.com/a HTTP/1.1\r\n"
            + "Host: example.com\r\n"
            + "Proxy-Authorization: Basic client-proxy-secret\r\n\r\n"
        ))
        let head = String(data: request.absoluteForwardHead(upstreamAuthorization: "Basic up"), encoding: .utf8) ?? ""
        #expect(head.hasPrefix("GET http://example.com/a HTTP/1.1\r\n"))
        #expect(head.contains("Proxy-Authorization: Basic up\r\n"))
        #expect(!head.contains("client-proxy-secret"))
    }
}
