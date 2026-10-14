import Foundation
import Testing
@testable import RelayDockCore

struct ProxyStoreTests {
    @Test func importsSupportedProxySchemesAndDeduplicates() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = try store.importProxies("""
        # pool
        http://alice:secret@proxy-a.example:8080
        https://proxy-b.example:8443
        socks5://127.0.0.1:1080
        socks5h://proxy-c.example:1081
        invalid.example
        http://alice:secret@proxy-a.example:8080
        """)

        #expect(state.proxies.count == 4)
        #expect(state.proxies[0].label == "proxy-a.example:8080")
        #expect(state.proxies[0].url.contains("alice:secret"))
        #expect(maskedProxyURL(state.proxies[0].url).contains("proxy-a.example:8080"))
        #expect(!maskedProxyURL(state.proxies[0].url).contains("secret"))
        #expect(state.proxies[0].id == proxyEntryID(for: state.proxies[0].url))
    }

    @Test func manualModeUsesOnlyTheSelectedEnabledProxy() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080\nhttp://proxy-b.example:8080")
        let selected = imported.proxies[1]

        _ = try store.setMode(.manual, manualId: selected.id)
        #expect(try store.selectForSpawn() == selected.url)

        _ = try store.setEnabled(selected.id, enabled: false)
        do {
            _ = try store.selectForSpawn()
            Issue.record("Manual mode must not bypass a disabled selected proxy")
        } catch {
            #expect(error as? ProxyStoreError == .manualSelectionDisabled(selected.label))
        }
    }

    @Test func autoModeKeepsStickyBindingsAndFailsClosed() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080\nhttp://proxy-b.example:8080")
        _ = try store.setMode(.auto, manualId: nil)

        #expect(try store.selectForSpawn(accountID: "account-a") == imported.proxies[0].url)
        #expect(try store.selectForSpawn(accountID: "account-b") == imported.proxies[1].url)
        #expect(try store.selectForSpawn(accountID: "account-a") == imported.proxies[0].url)

        var unhealthy = try store.load()
        unhealthy.proxies = unhealthy.proxies.map { entry in
            var changed = entry
            changed.health = ProxyHealth(ok: false, checkedAt: 1, error: "offline")
            return changed
        }
        _ = try store.save(unhealthy)
        do {
            _ = try store.selectForSpawn(accountID: "account-a")
            Issue.record("Auto mode must not fall back to a failed proxy or direct connection")
        } catch {
            #expect(error as? ProxyStoreError == .autoHasNoHealthyProxy)
        }

        _ = try store.setEnabled(imported.proxies[0].id, enabled: false)
        _ = try store.setEnabled(imported.proxies[1].id, enabled: false)
        do {
            _ = try store.selectForSpawn(accountID: "account-a")
            Issue.record("Auto mode with no enabled proxies must fail closed")
        } catch {
            #expect(error as? ProxyStoreError == .autoHasNoEnabledProxy)
        }
    }

    @Test func removalClearsManualAndStickyReferencesAndOffIsExplicitDirectMode() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080\nhttp://proxy-b.example:8080")
        var state = try store.setMode(.auto, manualId: imported.proxies[0].id)
        state.bindings = ["account-a": imported.proxies[0].id, "account-b": imported.proxies[1].id]
        _ = try store.save(state)
        let after = try store.remove(imported.proxies[0].id)

        #expect(after.manualId == nil)
        #expect(after.bindings == ["account-b": imported.proxies[1].id])
        _ = try store.setMode(.off, manualId: nil)
        #expect(try store.selectForSpawn() == nil)
    }

    @Test func readsLegacySnakeCaseProxyStateAndRejectsCorruptFiles() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"mode":"manual","manual_id":"px_old","proxies":[{"id":"px_old","url":"http://old.example:8080","enabled":true,"health":{"ok":true,"latency_ms":12,"checked_at":123}}],"bindings":{"account_1":"px_old"}}"#
        try Data(legacy.utf8).write(to: store.fileURL)

        let state = try store.load()
        #expect(state.manualId == "px_old")
        #expect(state.proxies[0].health?.latencyMs == 12)
        #expect(state.proxies[0].health?.checkedAt == 123)
        #expect(state.bindings["account_1"] == "px_old")

        try Data("broken".utf8).write(to: store.fileURL)
        do {
            _ = try store.load()
            Issue.record("Corrupt proxy configuration should be surfaced, not treated as Off")
        } catch {
            #expect(error is ProxyStoreError)
        }
    }

    @Test func proxyHealthTestsUseTheConfiguredProxyAndPersistOnlyEnabledResults() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = ProxyEntry(id: "failed", label: "Local closed port", url: "http://127.0.0.1:1")
        let disabled = ProxyEntry(
            id: "disabled",
            label: "Disabled",
            url: "http://127.0.0.1:1",
            enabled: false,
            health: ProxyHealth(ok: true, latencyMs: 10, checkedAt: 5)
        )
        _ = try store.save(ProxyState(mode: .auto, proxies: [failed, disabled]))

        let checked = try await store.checkAll()
        #expect(checked.proxies[0].health?.ok == false)
        #expect((checked.proxies[0].health?.checkedAt ?? 0) > 0)
        #expect(checked.proxies[1].health == disabled.health)
        #expect(try store.load() == checked)

        let invalid = await checkProxy("ftp://proxy.example:21")
        #expect(!invalid.ok)
        #expect(invalid.error == "Invalid proxy URL or unsupported protocol")
    }

    @Test func checkAllMergesHealthWithoutOverwritingConcurrentProxyChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ProxyCheckGate()
        let store = ProxyStore(configDirectory: directory, healthChecker: { url in await gate.check(url) })
        let imported = try store.importProxies("http://proxy-a.example:8080\nhttp://proxy-b.example:8080")

        let checkTask = Task { try await store.checkAll() }
        await gate.waitUntilStarted()

        let manual = try store.setMode(.manual, manualId: imported.proxies[0].id)
        #expect(try store.setEnabled(imported.proxies[0].id, enabled: false).mode == .manual)
        _ = try store.importProxies("http://proxy-c.example:8080")
        await gate.release()

        let checked = try await checkTask.value
        #expect(checked.mode == .manual)
        #expect(checked.manualId == manual.manualId)
        #expect(checked.proxies.count == 3)
        #expect(checked.proxies.first(where: { $0.id == imported.proxies[0].id })?.enabled == false)
        #expect(checked.proxies.first(where: { $0.id == imported.proxies[0].id })?.health?.ok == true)
    }

    private func makeStore() -> (URL, ProxyStore) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (directory, ProxyStore(configDirectory: directory))
    }
}

private actor ProxyCheckGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultWaiters: [CheckedContinuation<ProxyHealth, Never>] = []

    func check(_ url: String) async -> ProxyHealth {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { resultWaiters.append($0) }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        let waiters = resultWaiters
        resultWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ProxyHealth(ok: true, checkedAt: 1)) }
    }
}
