import Foundation
import RelayDockCore
import Testing

struct FreeUsageLimitStoreTests {
    @Test func sidecarOverlayExpiresAndDoesNotPolluteProxyConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-usage-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = ProxyEntry(
            id: "px_limited",
            label: "Limited gateway",
            url: "http://proxy.example:8080"
        )
        let proxyStore = ProxyStore(configDirectory: directory)
        _ = try proxyStore.save(ProxyState(mode: .auto, proxies: [entry]))
        let limits = FreeUsageLimitStore(configDirectory: directory)
        try limits.flag(entry.id, until: 2_000)

        let active = try proxyStore.loadWithFreeUsageLimits(now: 1_999)
        let expired = try proxyStore.loadWithFreeUsageLimits(now: 2_000)
        let persisted = try String(contentsOf: proxyStore.fileURL, encoding: .utf8)

        #expect(active.proxies[0].freeUsageLimitedUntil == 2_000)
        #expect(active.autoEligibleProxies(at: 1_999).isEmpty)
        #expect(expired.proxies[0].freeUsageLimitedUntil == nil)
        #expect(expired.autoEligibleProxies(at: 2_000).map(\.id) == [entry.id])
        #expect(!persisted.contains("freeUsageLimitedUntil"))
    }

    @Test func newerLimitDeadlineExtendsButNeverShortensCooldown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-usage-extend-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = FreeUsageLimitStore(configDirectory: directory)

        #expect(try limits.flag("px_a", until: 2_000) == 2_000)
        #expect(try limits.flag("px_a", until: 1_500) == 2_000)
        #expect(limits.applying(to: ProxyState(proxies: [
            ProxyEntry(id: "px_a", label: "A", url: "http://a.example:80")
        ]), now: 1_000).proxies[0].freeUsageLimitedUntil == 2_000)
    }

    @Test func successfulProbeClearsOnlyTheCooldownItObserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-usage-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = FreeUsageLimitStore(configDirectory: directory)
        try limits.flag("px_a", until: 2_000)
        try limits.flag("px_b", until: 3_000)

        #expect(try limits.clear("px_a", ifDeadlineMatches: 2_000))
        #expect(try !limits.clear("px_b", ifDeadlineMatches: 2_500))
        let state = ProxyState(proxies: [
            ProxyEntry(id: "px_a", label: "A", url: "http://a.example:80"),
            ProxyEntry(id: "px_b", label: "B", url: "http://b.example:80"),
        ])
        let updated = limits.applying(to: state, now: 1_000)
        #expect(updated.proxies[0].freeUsageLimitedUntil == nil)
        #expect(updated.proxies[1].freeUsageLimitedUntil == 3_000)
    }

    @Test func manualSpawnRefusesALimitedProxyUntilItsDeadline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-usage-manual-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyStore = ProxyStore(configDirectory: directory)
        let entry = ProxyEntry(id: "px_a", label: "A", url: "http://a.example:80")
        _ = try proxyStore.save(ProxyState(mode: .manual, manualId: entry.id, proxies: [entry]))
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(entry.id, until: Date().timeIntervalSince1970 + 3_600)

        do {
            _ = try proxyStore.selectForSpawn()
            Issue.record("manual routing must not reuse a proxy during its provider cooldown")
        } catch {
            guard case .proxyFreeUsageLimited(let label, _) = error as? ProxyStoreError else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(label == entry.label)
        }
    }

    @Test func autoSpawnExplainsWhenEveryProxyIsWaitingForReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-free-usage-auto-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let proxyStore = ProxyStore(configDirectory: directory)
        let entry = ProxyEntry(id: "px_a", label: "A", url: "http://a.example:80")
        _ = try proxyStore.save(ProxyState(mode: .auto, proxies: [entry]))
        let retryAt = Date().timeIntervalSince1970 + 3_600
        try FreeUsageLimitStore(configDirectory: directory).flag(entry.id, until: retryAt)

        do {
            _ = try proxyStore.selectForSpawn()
            Issue.record("Auto must fail closed while every proxy is rate-limited")
        } catch {
            #expect(error as? ProxyStoreError == .autoHasFreeUsageLimit(retryAt))
        }
    }
}
