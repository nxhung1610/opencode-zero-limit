import Foundation
import Testing
@testable import RelayDockEdge

struct EdgeDaemonTests {
    @Test func readsExpiryFromScriptSnapshots() {
        let now = 1_000_000.0
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiresAt": 1777000000000}"#, now: now) == 1_777_000_000)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expires_at": 1000500}"#, now: now) == 1_000_500)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiry": "1000600"}"#, now: now) == 1_000_600)
    }

    @Test func ignoresMissingStaleOrImplausibleExpiries() {
        let now = 1_000_000.0
        #expect(EdgeDaemon.snapshotExpiry(snapshot: nil, now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: "not json", now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"other": 1}"#, now: now) == nil)
        #expect(EdgeDaemon.snapshotExpiry(snapshot: #"{"expiresAt": 999000}"#, now: now) == nil)
    }
}
