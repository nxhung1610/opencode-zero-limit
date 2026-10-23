import RelayDockCore
import Testing
@testable import RelayDockApp

struct EdgePanelVerificationTests {
    @Test func routingOffIsNotPresentedAsProxied() {
        let status = makeStatus(mode: .off, tunnels: [
            makeTunnel(peerName: "opencode", label: "Proxy A", startedAt: 200),
        ])

        #expect(OpenCodeTrafficEvidence.resolve(from: status) == .routingOff)
    }

    @Test func directAndDirectFallbackTunnelsDoNotVerifyProxyTraffic() {
        let status = makeStatus(mode: .manual, tunnels: [
            makeTunnel(peerName: "opencode", label: nil, startedAt: 200),
            makeTunnel(peerName: "opencode.exe", label: "direct (fallback)", startedAt: 300),
        ])

        #expect(OpenCodeTrafficEvidence.resolve(from: status) == .notObserved)
    }

    @Test func latestOpenCodeProxyTunnelIsReported() {
        let status = makeStatus(mode: .manual, tunnels: [
            makeTunnel(peerName: "other-process", label: "Proxy A", startedAt: 500),
            makeTunnel(peerName: "opencode", label: "Proxy A", startedAt: 200, endedAt: 250),
            makeTunnel(peerName: "opencode.exe", label: "Proxy B", startedAt: 300),
        ])

        #expect(OpenCodeTrafficEvidence.resolve(from: status) == .observed(lastSeen: 300))
    }

    private func makeStatus(mode: ProxyMode, tunnels: [EdgeStatusResponse.Tunnel]) -> EdgeStatusResponse {
        EdgeStatusResponse(
            pid: 1,
            port: 57_211,
            mode: mode,
            tunnels: tunnels,
            launchedAt: 100
        )
    }

    private func makeTunnel(
        peerName: String?,
        label: String?,
        startedAt: Double,
        endedAt: Double? = nil
    ) -> EdgeStatusResponse.Tunnel {
        EdgeStatusResponse.Tunnel(
            clientPort: 50_000,
            peerPid: 10,
            peerName: peerName,
            label: label,
            startedAt: startedAt,
            endedAt: endedAt,
            active: endedAt == nil
        )
    }
}
