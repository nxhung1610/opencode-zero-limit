import Foundation
import Testing
@testable import RelayDockCore

struct OpenCodeProxyEnvironmentTests {
    @Test func explicitOffRemovesInheritedProxyAndPreservesLocalNoProxy() {
        let base = [
            "HTTP_PROXY": "http://inherited.example:8080",
            "HTTPS_PROXY": "http://inherited.example:8080",
            "no_proxy": "internal.example",
            "NO_PROXY": "localhost,example.test",
            "OPENCODE_SERVER_PASSWORD": "stale-secret",
            "OPENCODE_SERVER_USERNAME": "stale-user",
        ]

        let direct = buildOpenCodeProxyEnvironment(proxyURL: nil, base: base)

        #expect(direct["HTTP_PROXY"] == nil)
        #expect(direct["HTTPS_PROXY"] == nil)
        #expect(direct["NO_PROXY"] == "localhost,example.test,127.0.0.1")
        #expect(direct["no_proxy"] == "internal.example,localhost,127.0.0.1")
        #expect(direct["OPENCODE_SERVER_PASSWORD"] == nil)
        #expect(direct["OPENCODE_SERVER_USERNAME"] == nil)
    }

    @Test func selectedProxyOverridesEveryInheritedProxyVariable() {
        let base = [
            "HTTP_PROXY": "http://inherited.example:8080",
            "https_proxy": "http://inherited.example:8080",
        ]
        let selected = "socks5://proxy.example:1080"

        let environment = buildOpenCodeProxyEnvironment(proxyURL: selected, base: base)

        #expect(environment["HTTP_PROXY"] == selected)
        #expect(environment["http_proxy"] == selected)
        #expect(environment["HTTPS_PROXY"] == selected)
        #expect(environment["https_proxy"] == selected)
        #expect(environment["ALL_PROXY"] == selected)
        #expect(environment["all_proxy"] == selected)
    }
}
