import Foundation
import RelayDockCore
import Testing
@testable import RelayDockApp

@MainActor
struct RoutingModeWarningTests {
    @Test func manualSelectionDoesNotSaveUntilConfirmed() async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        await fixture.model.selectManualProxy(fixture.proxyID)

        let pending = try #require(fixture.model.pendingRoutingChange)
        #expect(fixture.model.state?.mode == .off)
        #expect(try fixture.store.load().mode == .off)
        fixture.model.confirmRoutingChange(pending)
        #expect(try fixture.store.load().mode == .manual)
        #expect(fixture.model.state?.manualId == fixture.proxyID)
        #expect(fixture.model.pendingRoutingChange == nil)
        #expect(fixture.model.hasOpenCodeRoutingNotice)
    }

    @Test(arguments: [RoutingChangeSource.window, .menu, .manualChooser])
    func everyEntryPointUsesTheSameGuard(source: RoutingChangeSource) async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        await fixture.model.selectManualProxy(fixture.proxyID, source: source)
        let pending = try #require(fixture.model.pendingRoutingChange)
        #expect(pending.source == source)
        fixture.model.cancelRoutingChange(pending.id)
        #expect(try fixture.store.load().mode == .off)
        #expect(fixture.model.pendingRoutingChange == nil)
    }

    @Test func autoAndManualModeSwitchesAreGuarded() async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        _ = try fixture.store.setMode(.off, manualId: fixture.proxyID)
        fixture.model.load()
        await fixture.model.selectMode(.manual)
        let manual = try #require(fixture.model.pendingRoutingChange)
        #expect(manual.mode == .manual)
        fixture.model.cancelRoutingChange(manual.id)
        await fixture.model.selectMode(.auto)
        let auto = try #require(fixture.model.pendingRoutingChange)
        #expect(auto.mode == .auto)
        #expect(try fixture.store.load().mode == .off)
    }

    @Test func idleOrUnavailableEvidenceDoesNotProduceABypassPopup() async throws {
        for report in [OpenCodeRoutingSnapshot(), .init(inspectionIncomplete: true), .init(servers: [
            .init(pid: 10, startedAt: 1, route: .edgeEnvironment),
        ])] {
            let fixture = try fixture(report: report)
            defer { fixture.remove() }
            await fixture.model.selectMode(.auto)
            #expect(fixture.model.pendingRoutingChange == nil)
            #expect(fixture.model.state?.mode == .auto)
            #expect(fixture.model.hasOpenCodeRoutingNotice == report.isUnverified)
        }
    }

    @Test func aCLIProxyTunnelCannotHideAnUnconfiguredServer() async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        fixture.model.applyEdgePanelForFixtures(.running(.init(
            pid: 1, port: 57_211, mode: .auto,
            tunnels: [.init(clientPort: 40_000, peerPid: 99, peerName: "opencode", label: "Proxy", startedAt: 1, active: true)],
            launchedAt: 1
        )))
        await fixture.model.selectMode(.auto)
        #expect(fixture.model.pendingRoutingChange?.report.affectedServers.first?.pid == 10)
    }

    @Test func confirmingAnOldWarningCannotOverwriteAnotherModeChange() async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        await fixture.model.selectMode(.auto)
        let pending = try #require(fixture.model.pendingRoutingChange)
        _ = try fixture.store.setMode(.manual, manualId: fixture.proxyID)
        fixture.model.confirmRoutingChange(pending)
        #expect(try fixture.store.load().mode == .manual)
        #expect(fixture.model.errorMessage?.contains("changed while checking") == true)
    }

    @Test func aDisabledSelectionIsRevalidatedOnConfirmation() async throws {
        let fixture = try fixture(report: outsideEdge)
        defer { fixture.remove() }
        await fixture.model.selectManualProxy(fixture.proxyID)
        let pending = try #require(fixture.model.pendingRoutingChange)
        _ = try fixture.store.setEnabled(fixture.proxyID, enabled: false)
        fixture.model.confirmRoutingChange(pending)
        #expect(try fixture.store.load().mode == .off)
        #expect(fixture.model.errorMessage != nil)
    }

    @Test func newerInspectionClearsThePersistentNotice() async throws {
        let reports = ReportSequence([outsideEdge, .init(servers: [.init(pid: 20, startedAt: 2, route: .edgeEnvironment)])])
        let fixture = try fixture(probe: { _ in await reports.next() })
        defer { fixture.remove() }
        await fixture.model.selectMode(.auto)
        fixture.model.confirmRoutingChange(try #require(fixture.model.pendingRoutingChange))
        #expect(fixture.model.hasOpenCodeRoutingNotice)
        await fixture.model.refreshOpenCodeRouting(force: true)
        #expect(!fixture.model.hasOpenCodeRoutingNotice)
    }

    @Test func closingAChooserDuringInspectionDoesNotSaveLater() async throws {
        let gate = ProbeGate()
        let fixture = try fixture(probe: { _ in await gate.wait() })
        defer { fixture.remove() }
        let task = Task { await fixture.model.selectManualProxy(fixture.proxyID, source: .manualChooser) }
        await gate.entered()
        fixture.model.cancelRoutingChanges(from: .manualChooser)
        await gate.release(.init())
        await task.value
        #expect(try fixture.store.load().mode == .off)
        #expect(fixture.model.pendingRoutingChange == nil)
    }

    @Test func offDoesNotProbeAndInvalidatesAnOutstandingRequest() async throws {
        let gate = ProbeGate()
        let fixture = try fixture(probe: { _ in await gate.wait() })
        defer { fixture.remove() }
        let task = Task { await fixture.model.selectMode(.auto) }
        await gate.entered()
        await fixture.model.selectMode(.off)
        await gate.release(outsideEdge)
        await task.value
        #expect(fixture.model.state?.mode == .off)
        #expect(fixture.model.pendingRoutingChange == nil)
        #expect(!fixture.model.isCheckingOpenCodeRouting)
    }

    private var outsideEdge: OpenCodeRoutingSnapshot {
        .init(servers: [.init(pid: 10, startedAt: 1, route: .missingProxy)])
    }

    private struct Fixture {
        var directory: URL
        var store: ProxyStore
        var model: ProxyAppModel
        var proxyID: String
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(report: OpenCodeRoutingSnapshot) throws -> Fixture {
        try fixture(probe: { _ in report })
    }

    private func fixture(
        probe: @escaping @Sendable (EdgeConfigFile?) async -> OpenCodeRoutingSnapshot
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ProxyStore(configDirectory: directory)
        let initial = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store, routingProbe: probe)
        model.load()
        return Fixture(directory: directory, store: store, model: model, proxyID: initial.proxies[0].id)
    }
}

private actor ReportSequence {
    var reports: [OpenCodeRoutingSnapshot]
    init(_ reports: [OpenCodeRoutingSnapshot]) { self.reports = reports }
    func next() -> OpenCodeRoutingSnapshot { reports.removeFirst() }
}

private actor ProbeGate {
    var continuation: CheckedContinuation<OpenCodeRoutingSnapshot, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func wait() async -> OpenCodeRoutingSnapshot {
        await withCheckedContinuation {
            continuation = $0
            observer?.resume()
            observer = nil
        }
    }
    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release(_ report: OpenCodeRoutingSnapshot) { continuation?.resume(returning: report); continuation = nil }
}
