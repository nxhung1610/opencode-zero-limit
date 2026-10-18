import Foundation
import Testing
@testable import RelayDockEdge

/// launchd socket activation plumbing (P3): the name mapping the plist and
/// the daemon share, plus the listener report the status payload is built
/// from.
struct EdgeSocketActivationTests {
    @Test func listenerNamesMatchThePlistOrder() {
        #expect(EdgeSocketActivation.primaryName == "Listeners")
        #expect(EdgeSocketActivation.listenerName(index: 0) == "Listeners-2")
        #expect(EdgeSocketActivation.listenerName(index: 1) == "Listeners-3")
    }

    @Test func aPlainProcessHasNoActivatedDescriptors() {
        // This test process was not launched by launchd with our Sockets
        // keys, so the lookup must come back empty and the caller binds its
        // own listener.
        #expect(EdgeSocketActivation.listeningDescriptors(named: "Listeners").isEmpty)
    }

    @Test func listenerReportKeepsOneEntryPerPortSorted() {
        let report = EdgeListenerReport()
        report.note(port: 57212, entryID: "px_b", activated: false)
        report.note(port: 57211, entryID: nil, activated: true)
        report.note(port: 57212, entryID: "px_b", activated: true)
        let snapshot = report.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot[0] == EdgeListenerReport.Entry(port: 57211, entryID: nil, activated: true))
        #expect(snapshot[1] == EdgeListenerReport.Entry(port: 57212, entryID: "px_b", activated: true))
    }
}
