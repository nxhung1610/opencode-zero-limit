import Foundation
import Testing
@testable import RelayDockCore

/// The status wire shape stays readable across versions (P3): an older Edge
/// binary has no `listeners` key, and the newer shape round-trips.
struct EdgeStatusListenersTests {
    @Test func decodesLegacyStatusWithoutListeners() throws {
        let json = #"""
        {"ok":true,"protocolVersion":1,"pid":1,"port":57211,"mode":"auto",
         "counters":{"resolutions":0,"switches":0,"dialFailures":0,"tunnelsTotal":0,"tunnelsActive":0},
         "tunnels":[],"launchedAt":1}
        """#
        let status = try JSONDecoder().decode(EdgeStatusResponse.self, from: Data(json.utf8))
        #expect(status.listeners.isEmpty)
    }

    @Test func roundTripsListeners() throws {
        let response = EdgeStatusResponse(
            pid: 1,
            port: 57211,
            mode: .auto,
            listeners: [EdgeStatusResponse.Listener(port: 57212, entryID: "px_b", activated: true)],
            launchedAt: 2
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(EdgeStatusResponse.self, from: data)
        #expect(decoded.listeners == response.listeners)
    }
}
