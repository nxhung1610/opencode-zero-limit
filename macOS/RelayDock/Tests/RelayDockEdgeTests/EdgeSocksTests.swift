import Foundation
import Testing
@testable import RelayDockEdge

struct EdgeSocksTests {
    @Test func buildsSOCKS5Greetings() {
        #expect(EdgeSocks.socks5Greeting(hasCredentials: false) == Data([0x05, 0x01, 0x00]))
        #expect(EdgeSocks.socks5Greeting(hasCredentials: true) == Data([0x05, 0x02, 0x00, 0x02]))
    }

    @Test func buildsSOCKS5AuthRequests() {
        let request = EdgeSocks.socks5AuthRequest(user: "u", password: "pw")
        #expect(request == Data([0x01, 0x01, 0x75, 0x02, 0x70, 0x77]))
    }

    @Test func buildsSOCKS5ConnectRequestsForIPv4() throws {
        let request = try #require(EdgeSocks.socks5Connect(host: "203.0.113.7", port: 8443, remoteDNS: false))
        #expect(request == Data([0x05, 0x01, 0x00, 0x01, 203, 0, 113, 7, 0x20, 0xFB]))
    }

    @Test func buildsSOCKS5ConnectRequestsForRemoteDNS() throws {
        let request = try #require(EdgeSocks.socks5Connect(host: "example.com", port: 443, remoteDNS: true))
        let expected = Data([0x05, 0x01, 0x00, 0x03, 11]) + Data("example.com".utf8) + Data([0x01, 0xBB])
        #expect(request == expected)
    }

    @Test func buildsSOCKS4aConnectRequests() throws {
        let request = try #require(EdgeSocks.socks4Connect(host: "example.com", port: 80, userID: "id", remoteDNS: true))
        let expected = Data([0x04, 0x01, 0x00, 0x50, 0x00, 0x00, 0x00, 0x01])
            + Data("id".utf8) + Data([0x00])
            + Data("example.com".utf8) + Data([0x00])
        #expect(request == expected)
    }

    @Test func buildsSOCKS4ConnectRequestsWithResolvedIPv4() throws {
        let request = try #require(EdgeSocks.socks4Connect(host: "203.0.113.9", port: 8080, userID: "", remoteDNS: false))
        #expect(request == Data([0x04, 0x01, 0x1F, 0x90, 203, 0, 113, 9, 0x00]))
    }

    @Test func rejectsUnresolvableHostsInLocalDNSModes() {
        #expect(EdgeSocks.socks5Connect(host: "no-such-host.invalid", port: 80, remoteDNS: false) == nil)
        #expect(EdgeSocks.socks4Connect(host: "no-such-host.invalid", port: 80, userID: "", remoteDNS: false) == nil)
    }

    @Test func formatsAuthoritiesWithIPv6Brackets() {
        #expect(EdgeSocks.formatAuthority("example.com", port: 443) == "example.com:443")
        #expect(EdgeSocks.formatAuthority("2606:4700::1111", port: 443) == "[2606:4700::1111]:443")
    }

    @Test func detectsIPAddresses() {
        #expect(EdgeSocks.isIPAddress("127.0.0.1"))
        #expect(EdgeSocks.isIPAddress("::1"))
        #expect(!EdgeSocks.isIPAddress("example.com"))
    }

    @Test func schemesAreReadFromUpstreamURLs() {
        #expect(EdgeDialer.scheme(of: "socks5h://user:pass@127.0.0.1:1080") == "socks5h")
        #expect(EdgeDialer.scheme(of: "http://127.0.0.1:8080") == "http")
        #expect(EdgeDialer.scheme(of: "not a url") == nil)
    }
}
