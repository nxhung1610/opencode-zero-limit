import Foundation
import Testing
@testable import RelayDockEdge

/// Warm hop pool planning (P3 upstream pooling): which upstream URLs can be
/// pre-dialed, and how pooled sockets are keyed. Credentials must never
/// enter the key — a pooled socket carries no application bytes.
struct EdgeHopPoolTests {
    @Test func plansDialTargetsForEverySupportedScheme() {
        #expect(
            EdgeHopPool.dialTarget(for: "http://u:p@proxy.example:8080")
                == EdgeHopPool.Target(host: "proxy.example", port: 8080, tls: false)
        )
        #expect(
            EdgeHopPool.dialTarget(for: "https://proxy.example:8443")
                == EdgeHopPool.Target(host: "proxy.example", port: 8443, tls: true)
        )
        #expect(
            EdgeHopPool.dialTarget(for: "socks5h://127.0.0.1:1080")
                == EdgeHopPool.Target(host: "127.0.0.1", port: 1080, tls: false)
        )
        #expect(EdgeHopPool.dialTarget(for: "ftp://proxy.example:21") == nil)
        #expect(EdgeHopPool.dialTarget(for: "not a url") == nil)
    }

    @Test func keysIgnoreCredentialsAndTrackTLS() {
        #expect(EdgeHopPool.key(for: "http://alice:secret@proxy.example:8080") == "tcp://proxy.example:8080")
        #expect(EdgeHopPool.key(for: "http://bob:other@proxy.example:8080") == "tcp://proxy.example:8080")
        #expect(EdgeHopPool.key(for: "https://proxy.example:8080") == "tls://proxy.example:8080")
        #expect(EdgeHopPool.key(for: "ftp://proxy.example:21") == nil)
    }
}
