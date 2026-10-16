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
        http://alice:secret@proxy-a.example:8080
        """)

        #expect(state.proxies.count == 4)
        #expect(state.proxies[0].label == "proxy-a.example:8080")
        #expect(state.proxies[0].url.contains("alice:secret"))
        #expect(maskedProxyURL(state.proxies[0].url).contains("proxy-a.example:8080"))
        #expect(!maskedProxyURL(state.proxies[0].url).contains("secret"))
        #expect(maskedProxyURL(state.proxies[0].url) == "http://•••@proxy-a.example:8080")
        #expect(state.proxies[0].id == proxyEntryID(for: state.proxies[0].url))
    }

    @Test func invalidImportReportsLineNumbersAndDoesNotPartiallySave() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = try store.importProxies("http://proxy-a.example:8080")

        do {
            _ = try store.importProxies("""
            # supported comment
            not-a-proxy
            ftp://proxy-b.example:21
            """)
            Issue.record("Import should report malformed and unsupported proxy URLs")
        } catch {
            #expect(error as? ProxyStoreError == .invalidImportLines([2, 3]))
        }

        #expect(try store.load() == existing)
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

    @Test func manualModeRejectsASelectionThatIsAlreadyDisabled() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy-a.example:8080")
        let selected = imported.proxies[0]
        let disabledState = try store.setEnabled(selected.id, enabled: false)

        do {
            _ = try store.setMode(.manual, manualId: selected.id)
            Issue.record("Manual mode must reject a disabled proxy selection")
        } catch {
            #expect(error as? ProxyStoreError == .manualSelectionDisabled(selected.label))
        }

        #expect(try store.load() == disabledState)
    }

    @Test func manualModeCannotSilentlyBecomeDirectOffWithoutASelection() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try store.importProxies("http://proxy-a.example:8080")

        for selection: String? in [nil, "missing-proxy"] {
            do {
                _ = try store.setMode(.manual, manualId: selection)
                Issue.record("Manual mode without a valid selection must fail rather than switch to Off")
            } catch {
                #expect(error as? ProxyStoreError == .noManualSelection)
            }
            #expect(try store.load() == initial)
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

    @Test func autoReadinessSummaryIsNonMutatingAndMatchesSelectionRules() {
        let proxies = [
            ProxyEntry(id: "passed", label: "Passed", url: "http://passed.example:8080", health: ProxyHealth(ok: true)),
            ProxyEntry(id: "unchecked", label: "Unchecked", url: "http://unchecked.example:8080"),
            ProxyEntry(id: "failed", label: "Failed", url: "http://failed.example:8080", health: ProxyHealth(ok: false)),
            ProxyEntry(id: "disabled", label: "Disabled", url: "http://disabled.example:8080", enabled: false),
            ProxyEntry(id: "invalid", label: "Invalid", url: "ftp://invalid.example:21"),
        ]
        let state = ProxyState(mode: .auto, proxies: proxies)

        #expect(state.enabledProxies.map(\.id) == ["passed", "unchecked", "failed", "invalid"])
        #expect(state.validEnabledProxies.map(\.id) == ["passed", "unchecked", "failed"])
        #expect(state.autoEligibleProxies.map(\.id) == ["passed", "unchecked"])
        #expect(state.bindings.isEmpty)
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

    @Test func missingOrUnknownPersistedModeIsNotSilentlyTreatedAsDirectOff() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for contents in [#"{"proxies":[]}"#, #"{"mode":"autmo","proxies":[]}"#] {
            try Data(contents.utf8).write(to: store.fileURL)
            do {
                _ = try store.selectForSpawn()
                Issue.record("A missing or invalid mode must not be interpreted as explicit Off mode")
            } catch {
                #expect(error is ProxyStoreError)
            }
        }
    }

    @Test func invalidPersistedProxyURLsFailClosedInManualAndAutoModes() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = ProxyEntry(id: "bad", label: "Unsupported", url: "ftp://proxy.example:21")
        _ = try store.save(ProxyState(mode: .manual, manualId: unsupported.id, proxies: [unsupported]))

        do {
            _ = try store.selectForSpawn()
            Issue.record("Manual mode must reject a persisted unsupported proxy URL")
        } catch {
            #expect(error as? ProxyStoreError == .invalidProxyConfiguration(unsupported.label))
        }

        _ = try store.save(ProxyState(mode: .auto, proxies: [unsupported]))
        do {
            _ = try store.selectForSpawn()
            Issue.record("Auto mode must not choose a persisted unsupported proxy URL")
        } catch {
            #expect(error as? ProxyStoreError == .autoHasNoValidProxy)
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

    @Test func checkAllLimitsConcurrentHealthRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = ProxyCheckConcurrencyTracker()
        let store = ProxyStore(configDirectory: directory, healthChecker: { url in await tracker.check(url) })
        let proxies = (0..<12).map { index in
            ProxyEntry(
                id: "proxy-\(index)",
                label: "Proxy \(index)",
                url: "http://proxy-\(index).example:8080"
            )
        }
        _ = try store.save(ProxyState(proxies: proxies))

        _ = try await store.checkAll()

        let maximum = await tracker.maximumConcurrentChecks()
        #expect(maximum <= 4)
        #expect(maximum > 1)
    }

    @Test func importsSocks4AndSocks4AProxies() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = try store.importProxies("""
        socks4://proxy-d.example:1080
        socks4a://[2001:db8::1]:1080
        SOCKS4://proxy-e.example:1081
        """)

        #expect(state.proxies.count == 3)
        #expect(state.proxies.map(\.url) == [
            "socks4://proxy-d.example:1080",
            "socks4a://[2001:db8::1]:1080",
            "SOCKS4://proxy-e.example:1081",
        ])
        #expect(state.proxies[1].label == "[2001:db8::1]:1080")
    }

    @Test func singleAddValidatesDeduplicatesAndPersists() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = try store.addProxyURL("socks5://alice:secret@edge.example:1080")
        #expect(state.proxies.count == 1)
        #expect(state.proxies[0].url == "socks5://alice:secret@edge.example:1080")
        #expect(state.proxies[0].label == "edge.example:1080")
        #expect(try store.load() == state)

        do {
            _ = try store.addProxyURL("socks5://alice:secret@edge.example:1080")
            Issue.record("Adding the same proxy twice must be reported")
        } catch {
            #expect(error as? ProxyStoreError == .proxyAlreadyExists("edge.example:1080"))
        }

        for invalid in ["ftp://edge.example:21", "not-a-proxy"] {
            do {
                _ = try store.addProxyURL(invalid)
                Issue.record("Adding \(invalid) must be rejected")
            } catch {
                #expect(error as? ProxyStoreError == .invalidSingleProxy)
            }
        }
    }

    @Test func customScriptEntriesResolveAtSpawnTime() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = "return \"socks5://127.0.0.1:1080\";"
        let added = try store.addProxyScript(name: "Local relay", script: script)
        #expect(added.proxies.count == 1)
        #expect(added.proxies[0].script == script)
        #expect(added.proxies[0].url == "")
        #expect(added.proxies[0].label == "Local relay")
        #expect(added.proxies[0].id == proxyScriptEntryID(for: script))
        #expect(try store.load() == added)

        let selected = added.proxies[0]
        _ = try store.setMode(.manual, manualId: selected.id)
        #expect(try store.selectForSpawn() == "socks5://127.0.0.1:1080")

        _ = try store.setMode(.auto, manualId: nil)
        #expect(try store.selectForSpawn(accountID: "account-a") == "socks5://127.0.0.1:1080")
    }

    @Test func customScriptFailuresFailClosed() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = try store.addProxyScript(name: "Broken", script: "throw new Error(\"boom\");")
        _ = try store.setMode(.manual, manualId: state.proxies[0].id)

        do {
            _ = try store.selectForSpawn()
            Issue.record("A failing script must not produce a route")
        } catch {
            guard case .scriptFailed(let label, let reason)? = error as? ProxyStoreError else {
                Issue.record("Expected scriptFailed, got \(error)")
                return
            }
            #expect(label == "Broken")
            #expect(reason.contains("boom"))
        }

        _ = try store.setMode(.auto, manualId: nil)
        do {
            _ = try store.selectForSpawn()
            Issue.record("Auto mode must fail closed when the only script fails")
        } catch {
            #expect(error is ProxyStoreError)
        }
    }

    @Test func customScriptEntriesValidateNameAndScriptAndDeduplicate() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try store.addProxyScript(name: "   ", script: "return \"http://edge.example:8080\";")
            Issue.record("A nameless script must be rejected")
        } catch {
            #expect(error as? ProxyStoreError == .scriptNameRequired)
        }
        do {
            _ = try store.addProxyScript(name: "Empty", script: "   ")
            Issue.record("An empty script must be rejected")
        } catch {
            #expect(error as? ProxyStoreError == .scriptEmpty)
        }

        let script = "return \"http://edge.example:8080\";"
        _ = try store.addProxyScript(name: "First", script: script)
        do {
            _ = try store.addProxyScript(name: "Second", script: script)
            Issue.record("Duplicate scripts must be rejected")
        } catch {
            #expect(error as? ProxyStoreError == .proxyAlreadyExists("This script"))
        }
    }

    @Test func customScriptEntriesCountAsValidDefinitions() {
        let proxies = [
            ProxyEntry(id: "script", label: "Script", url: "", script: "return \"http://edge.example:8080\";"),
            ProxyEntry(id: "blank", label: "Blank", url: "", script: "   "),
            ProxyEntry(id: "invalid-url", label: "Invalid", url: "ftp://invalid.example:21"),
        ]
        let state = ProxyState(mode: .auto, proxies: proxies)

        #expect(state.validEnabledProxies.map(\.id) == ["script"])
        #expect(state.autoEligibleProxies.map(\.id) == ["script"])
    }

    @Test func scriptHealthChecksResolveTheScriptBeforeChecking() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ScriptURLRecorder()
        let store = ProxyStore(configDirectory: directory, healthChecker: { url in await recorder.check(url) })
        _ = try store.addProxyScript(name: "Custom", script: "return \"socks5://127.0.0.1:1080\";")
        _ = try store.addProxyURL("http://proxy-a.example:8080")

        let checked = try await store.checkAll()

        let urls = await recorder.checkedURLs()
        #expect(urls.contains("socks5://127.0.0.1:1080"))
        #expect(urls.contains("http://proxy-a.example:8080"))
        #expect(checked.proxies.first(where: { $0.script != nil })?.health?.ok == true)
    }

    @Test func failingScriptsRecordAFailedHealthCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(configDirectory: directory, healthChecker: { _ in ProxyHealth(ok: true, checkedAt: 1) })
        _ = try store.addProxyScript(name: "Broken", script: "throw new Error(\"boom\");")

        let checked = try await store.checkAll()

        let health = checked.proxies[0].health
        #expect(health?.ok == false)
        #expect(health?.error?.contains("boom") == true)
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

private actor ProxyCheckConcurrencyTracker {
    private var activeChecks = 0
    private var maximumActiveChecks = 0

    func check(_ url: String) async -> ProxyHealth {
        activeChecks += 1
        maximumActiveChecks = max(maximumActiveChecks, activeChecks)
        try? await Task.sleep(for: .milliseconds(25))
        activeChecks -= 1
        return ProxyHealth(ok: true, checkedAt: 1)
    }

    func maximumConcurrentChecks() -> Int {
        maximumActiveChecks
    }
}

private actor ScriptURLRecorder {
    private var urls: [String] = []

    func check(_ url: String) async -> ProxyHealth {
        urls.append(url)
        return ProxyHealth(ok: true, checkedAt: 1)
    }

    func checkedURLs() -> [String] {
        urls
    }
}
