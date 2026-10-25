import Foundation
import RelayDockCore
import Testing
@testable import RelayDockApp

struct ProxyAppModelTests {
    @Test @MainActor func manualModeRequiresAnExplicitEnabledProxy() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store, routingProbe: { _ in .init() })
        model.load()

        await model.selectMode(.manual)

        #expect(model.state?.mode == .off)
        #expect(model.isManualChooserPresented)

        await model.selectManualProxy(imported.proxies[0].id)

        #expect(model.state?.mode == .manual)
        #expect(model.state?.manualId == imported.proxies[0].id)
        #expect(!model.isManualChooserPresented)
    }

    @Test @MainActor func unreadableConfigurationDoesNotAppearAsDirectOff() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"mode":"manual","proxies":[}"#.utf8).write(to: store.fileURL)
        let model = ProxyAppModel(store: store)

        model.load()

        #expect(model.state == nil)
        #expect(model.loadError != nil)
    }

    @Test @MainActor func invalidImportPreservesExistingPoolAndReportsError() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()

        let error = model.importProxies("ftp://unsupported.example:21")

        #expect(error?.contains("line 1") == true)
        #expect(model.state == initial)
    }

    @Test @MainActor func manualSelectionUsabilityTracksEnabledAndValidState() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store, routingProbe: { _ in .init() })
        model.load()

        #expect(!model.manualSelectionIsUsable)

        await model.selectManualProxy(imported.proxies[0].id)
        #expect(model.manualSelectionIsUsable)

        model.setEnabled(imported.proxies[0].id, enabled: false)
        #expect(!model.manualSelectionIsUsable)
    }

    @Test @MainActor func manualModeSwitchesDirectlyWhenSelectionIsUsable() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(store: store, routingProbe: { _ in .init() })
        model.load()
        await model.selectManualProxy(imported.proxies[0].id)
        await model.selectMode(.off)

        await model.selectMode(.manual)

        #expect(model.state?.mode == .manual)
        #expect(!model.isManualChooserPresented)
    }

    @Test @MainActor func directFallbackTogglePersistsThroughTheStore() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ProxyAppModel(store: store)
        model.load()

        #expect(model.state?.directFallback == false)

        model.setDirectFallback(true)
        #expect(model.state?.directFallback == true)
        #expect(try store.load().directFallback)

        model.setDirectFallback(false)
        #expect(model.state?.directFallback == false)
        #expect(try store.load().directFallback == false)
    }

    @Test @MainActor func testAllSharesTheEdgeScriptCacheOnDisk() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try store.addProxyScript(
            name: "Edge cache",
            script: """
            if (cache.url) { return cache.url; }
            throw new Error('the script must not run when the Edge cache has a snapshot');
            """
        )
        let entryID = state.proxies[0].id
        let snapshot = #"{"url":"http://127.0.0.1:9101"}"#
        let cacheFileURL = directory.appending(path: ScriptCacheFile.fileName)
        var seeded = ScriptCacheFile.make(snapshots: [entryID: snapshot], state: state)
        seeded.entries["px_someone_else"] = .init(scriptHash: "other", snapshot: #"{"keep":1}"#)
        try seeded.save(to: cacheFileURL)

        let model = ProxyAppModel(store: store)
        model.load()
        await model.testAll()

        // The snapshot came from the file, not from running the failing script.
        let health = model.state?.proxies.first(where: { $0.id == entryID })?.health
        #expect(health?.ok == false)
        #expect(health?.error?.contains("must not run") == false)

        // The export merged back without dropping a snapshot only the file had.
        let remaining = ScriptCacheFile.load(from: cacheFileURL)
        #expect(remaining.entries[entryID]?.snapshot.contains("9101") == true)
        #expect(remaining.entries["px_someone_else"]?.snapshot == #"{"keep":1}"#)
    }

    @Test @MainActor func testAllDelegatesToEdgeAndPersistsItsResults() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let entryID = imported.proxies[0].id
        try writeEdgeConfig(in: directory)
        let checkedAt = Date().timeIntervalSince1970 * 1_000
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: [
                    entryID: .init(ok: true, latencyMs: 42, checkedAt: checkedAt),
                ])
            },
            freeModelProvider: { nil }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .edge)
        let health = model.state?.proxies.first(where: { $0.id == entryID })?.health
        #expect(health?.ok == true)
        #expect(health?.latencyMs == 42)
    }

    @Test @MainActor func testAllReprobesLimitedEntriesButSkipsFailedAndDisabledEntries() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies(
            "http://healthy.example:8080\nhttp://failed.example:8081\nhttp://limited.example:8082\nhttp://disabled.example:8083"
        )
        let healthyID = imported.proxies[0].id
        let failedID = imported.proxies[1].id
        let limitedID = imported.proxies[2].id
        let disabledID = imported.proxies[3].id
        _ = try store.setEnabled(disabledID, enabled: false)
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(limitedID, until: Date().timeIntervalSince1970 + 3_600)
        try writeEdgeConfig(in: directory)
        let recorder = OpenCodeProbeRecorder()
        let model = ProxyAppModel(
            store: store,
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: [
                    healthyID: .init(ok: true, latencyMs: 12, checkedAt: 1),
                    failedID: .init(ok: false, checkedAt: 1, error: "unreachable"),
                    limitedID: .init(ok: true, latencyMs: 14, checkedAt: 1),
                ])
            },
            freeModelProvider: { "opencode/beam-free" },
            freeUsageProbe: { entry, proxyURL, config, model in
                recorder.record(entryID: entry.id, proxyURL: proxyURL, port: config.port, model: model)
                return entry.id == healthyID ? .freeUsageLimited(retryAfterMs: 3_600_000) : .passed
            }
        )
        model.load()

        await model.testAll()

        #expect(Set(recorder.records.map(\.entryID)) == Set([healthyID, limitedID]))
        #expect(recorder.records.allSatisfy { $0.port == 57_211 && $0.model == "opencode/beam-free" })
        #expect(model.state?.proxies.first(where: { $0.id == healthyID })?.isFreeUsageLimited() == true)
        #expect(model.state?.proxies.first(where: { $0.id == limitedID })?.isFreeUsageLimited() == false)
        #expect(model.state?.proxies.first(where: { $0.id == disabledID })?.enabled == false)
        #expect(model.state?.proxies.first(where: { $0.id == disabledID })?.isFreeUsageLimited() == false)
    }

    @Test @MainActor func retryFreeUsageClearsACooldownOnlyWhenTheProbePasses() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://limited.example:8080")
        let entryID = imported.proxies[0].id
        try writeEdgeConfig(in: directory)
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(entryID, until: Date().timeIntervalSince1970 + 3_600)
        let recorder = OpenCodeProbeRecorder()
        let model = ProxyAppModel(
            store: store,
            freeModelProvider: { "opencode/beam-free" },
            freeUsageProbe: { entry, proxyURL, config, probeModel in
                recorder.record(entryID: entry.id, proxyURL: proxyURL, port: config.port, model: probeModel)
                return .passed
            }
        )
        model.load()
        #expect(model.state?.proxies[0].isFreeUsageLimited() == true)

        await model.retryFreeUsage(for: entryID)

        #expect(recorder.records.map(\.entryID) == [entryID])
        #expect(model.state?.proxies[0].isFreeUsageLimited() == false)
        #expect(model.freeUsageRetryMessages[entryID]?.contains("back in rotation") == true)
    }

    @Test @MainActor func retryFreeUsageKeepsTheCooldownWhenTheProbeStillReportsALimit() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://limited.example:8080")
        let entryID = imported.proxies[0].id
        try writeEdgeConfig(in: directory)
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(entryID, until: Date().timeIntervalSince1970 + 3_600)
        let model = ProxyAppModel(
            store: store,
            freeModelProvider: { "opencode/beam-free" },
            freeUsageProbe: { _, _, _, _ in .freeUsageLimited(retryAfterMs: 7_200_000) }
        )
        model.load()

        await model.retryFreeUsage(for: entryID)

        #expect(model.state?.proxies[0].isFreeUsageLimited() == true)
        #expect(model.freeUsageRetryMessages[entryID]?.contains("still limited") == true)
    }

    @Test @MainActor func automaticReprobeRunsOnlyNearResetAndOncePerCooldown() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://soon.example:8080\nhttp://later.example:8080")
        let soonID = imported.proxies[0].id
        let laterID = imported.proxies[1].id
        try writeEdgeConfig(in: directory)
        _ = try store.setMode(.auto, manualId: nil)
        let now = Date()
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(soonID, until: now.timeIntervalSince1970 + 600)
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(laterID, until: now.timeIntervalSince1970 + 3 * 3_600)
        let recorder = OpenCodeProbeRecorder()
        let model = ProxyAppModel(
            store: store,
            freeModelProvider: { "opencode/beam-free" },
            freeUsageProbe: { entry, proxyURL, config, probeModel in
                recorder.record(entryID: entry.id, proxyURL: proxyURL, port: config.port, model: probeModel)
                return .passed
            }
        )
        model.load()

        await model.reprobeFreeUsageIfDue(now: now)

        #expect(recorder.records.map(\.entryID) == [soonID])
        #expect(model.state?.proxies.first(where: { $0.id == soonID })?.isFreeUsageLimited() == false)
        #expect(model.state?.proxies.first(where: { $0.id == laterID })?.isFreeUsageLimited() == true)

        // The interval gate blocks the same check on the next poll tick.
        await model.reprobeFreeUsageIfDue(now: now.addingTimeInterval(60))
        #expect(recorder.records.count == 1)

        // The entry with hours left is not probed just because the interval
        // elapsed; only a reset that is actually close qualifies.
        await model.reprobeFreeUsageIfDue(now: now.addingTimeInterval(601))
        #expect(recorder.records.count == 1)

        let laterDeadline = now.timeIntervalSince1970 + 3 * 3_600
        await model.reprobeFreeUsageIfDue(now: Date(timeIntervalSince1970: laterDeadline - 300))
        #expect(recorder.records.map(\.entryID) == [soonID, laterID])
        #expect(model.state?.proxies.first(where: { $0.id == laterID })?.isFreeUsageLimited() == false)
    }

    @Test @MainActor func sharedFreeUsageWarningRequiresClusteredDeadlines() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://first.example:8080\nhttp://second.example:8080")
        let now = Date().timeIntervalSince1970
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(imported.proxies[0].id, until: now + 3_600)
        try FreeUsageLimitStore(configDirectory: directory)
            .flag(imported.proxies[1].id, until: now + 3_780)
        let clustered = ProxyAppModel(store: store)
        clustered.load()

        #expect(clustered.sharedFreeUsageLimitWarning?.contains("2 proxies") == true)

        let (spreadDirectory, spreadStore) = makeStore()
        defer { try? FileManager.default.removeItem(at: spreadDirectory) }
        let spread = try spreadStore.importProxies("http://first.example:8080\nhttp://second.example:8080")
        try FreeUsageLimitStore(configDirectory: spreadDirectory)
            .flag(spread.proxies[0].id, until: now + 3_600)
        try FreeUsageLimitStore(configDirectory: spreadDirectory)
            .flag(spread.proxies[1].id, until: now + 7_200)
        let spreadModel = ProxyAppModel(store: spreadStore)
        spreadModel.load()

        #expect(spreadModel.sharedFreeUsageLimitWarning == nil)
    }

    @Test @MainActor func testAllRunsQuotaProbesInParallelAndUpdatesRowsAsTheyFinish() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies(
            "http://first.example:8080\nhttp://second.example:8080\nhttp://third.example:8080"
        )
        try writeEdgeConfig(in: directory)
        let ids = imported.proxies.map(\.id)
        let recorder = ConcurrentProbeRecorder()
        let model = ProxyAppModel(
            store: store,
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: Dictionary(uniqueKeysWithValues: ids.map {
                    ($0, .init(ok: true, latencyMs: 10, checkedAt: 1))
                }))
            },
            freeModelProvider: { "opencode/mimo-v2.6-flash-free" },
            freeUsageProbe: { entry, _, _, _ in
                await recorder.started(entry.id)
                await recorder.waitForRelease(entry.id)
                await recorder.finished()
                return .passed
            }
        )
        model.load()

        let testRun = Task { await model.testAll() }
        await recorder.waitUntilStarted(ids.count)
        #expect(ids.allSatisfy { model.freeUsageProbeStatuses[$0] == .checking })

        // Hold the slower probes until the first result has reached the model.
        // This proves progressive UI state without relying on a timing window
        // that can disappear under load from the AppKit performance fixtures.
        await recorder.release(ids[0])
        for _ in 0..<500 {
            if model.freeUsageProbeStatuses[ids[0]] == .passed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let observedProgressiveCompletion = model.freeUsageProbeStatuses[ids[0]] == .passed
            && ids.dropFirst().allSatisfy { model.freeUsageProbeStatuses[$0] == .checking }
        await recorder.release(ids[1])
        await recorder.release(ids[2])
        await testRun.value

        #expect(await recorder.maximumConcurrent() == ids.count)
        #expect(observedProgressiveCompletion)
        #expect(model.freeUsageProbeStatuses[ids[0]] == .passed)
        #expect(model.freeUsageProbeStatuses[ids[1]] == .passed)
        #expect(model.freeUsageProbeStatuses[ids[2]] == .passed)
    }

    @Test func freeModelParserOnlyReturnsOpenCodeFreeModels() {
        let output = """
        openai/gpt-6.1-sol
        opencode/beam-free
        opencode/mimo-v2.6-flash-free
        opencode/big-pickle
        opencode/paid-model
        opencode/deepseek-v4.1-flash-free
        """
        #expect(OpenCodeFreeUsageProbe.freeModelIDs(in: output) == [
            "opencode/beam-free", "opencode/mimo-v2.6-flash-free", "opencode/big-pickle",
            "opencode/deepseek-v4.1-flash-free",
        ])
    }

    @Test func findFreeModelPrefersMimoV26FlashFree() async {
        let model = await OpenCodeFreeUsageProbe.findFreeModel(environment: [:]) { _, _, _ in
            .init(
                status: 0,
                stdout: "opencode/beam-free\nopencode/mimo-v2.6-flash-free\nopencode/big-pickle\n",
                timedOut: false
            )
        }

        #expect(model == "opencode/mimo-v2.6-flash-free")
    }

    @Test func freeUsageLimitOutputPreservesProviderCooldown() {
        let cooldown = OpenCodeFreeUsageProbe.freeUsageLimitCooldown(
            in: #"{"error":{"name":"FreeUsageLimitError","retryAfterMs":3600000}}"#,
            nowMilliseconds: 1_000
        )

        #expect(cooldown == 3_600_000)
        #expect(OpenCodeFreeUsageProbe.freeUsageLimitCooldown(in: "request completed") == nil)
    }

    @Test func freeUsageLimitFallbackWaitsUntilUTCMidnight() {
        // 2026-10-25T23:59:00Z, 23:59:59.500Z, 2026-10-26T00:00:00Z, noon UTC.
        let cases: [(now: Double, expected: Double)] = [
            (1_792_972_740_000, 60_000),
            (1_792_972_799_500, 1_000),
            (1_792_972_800_000, 86_400_000),
            (1_792_929_600_000, 43_200_000),
        ]
        for testCase in cases {
            let cooldown = OpenCodeFreeUsageProbe.freeUsageLimitCooldown(
                in: #"{"error":{"name":"FreeUsageLimitError"}}"#,
                nowMilliseconds: testCase.now
            )
            #expect(cooldown == testCase.expected)
        }
    }

    @Test func freeUsageLimitStructuredCooldownWinsAndPastResetClampsToOneSecond() {
        #expect(OpenCodeFreeUsageProbe.freeUsageLimitCooldown(
            in: #"{"error":{"name":"FreeUsageLimitError","retryAfter":3600}}"#,
            nowMilliseconds: 1_000
        ) == 3_600_000)
        #expect(OpenCodeFreeUsageProbe.freeUsageLimitCooldown(
            in: #"{"error":{"name":"FreeUsageLimitError","resetAtMs":1000}}"#,
            nowMilliseconds: 2_000
        ) == 1_000)
        #expect(OpenCodeFreeUsageProbe.defaultCooldownMilliseconds(nowMilliseconds: 0) == 86_400_000)
    }

    @Test func liveFreeUsageProbeUsesAnIsolatedLoopbackEdgePinnedToTheTarget() async {
        let entry = ProxyEntry(id: "px_probe", label: "Probe", url: "http://proxy.example:8080")
        let recorder = OpenCodeCommandRecorder()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outcome = await OpenCodeFreeUsageProbe.run(
            entry: entry,
            proxyURL: entry.url,
            edgeConfig: EdgeConfigFile(port: 57_211),
            model: "opencode/beam-free",
            environment: ["HTTP_PROXY": "http://old-proxy.example:3128"],
            runner: { command, environment, timeout in
                recorder.record(command: command, environment: environment, timeout: timeout)
                return .init(status: 0, stdout: "", timedOut: false)
            },
            bridgeFactory: { _, _, _ in
                .init(
                    proxyURL: "http://127.0.0.1:57212",
                    port: 57_212,
                    configDirectory: temporaryDirectory,
                    cleanup: {}
                )
            }
        )
        let run = recorder.snapshot

        #expect(outcome == .passed)
        #expect(run?.command.contains("opencode run --standalone") == true)
        #expect(run?.command.contains("opencode/beam-free") == true)
        #expect(run?.environment["HTTP_PROXY"] == "http://127.0.0.1:57212")
        #expect(run?.environment["HTTPS_PROXY"] == "http://127.0.0.1:57212")
        #expect(run?.environment["RELAYDOCK_TEST_PROXY_URL"] == "http://127.0.0.1:57212")
        #expect(run?.environment["NO_PROXY"] == "localhost,127.0.0.1")
        #expect(run?.environment["no_proxy"] == "localhost,127.0.0.1")
        #expect(run?.environment["RELAYDOCK_TEST_PROXY_ID"] == entry.id)
        #expect(run?.environment["RELAYDOCK_TEST_EDGE_PORT"] == "57212")
        #expect(run?.timeout == 45)
    }

    @Test @MainActor func testAllFallsBackInProcessWhenEdgeIsNotConfigured() async throws {
        let (directory, store) = makeStore(checker: { _ in
            ProxyHealth(ok: true, latencyMs: 5, checkedAt: 1)
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy.example:8080")
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in nil }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .inApp)
        #expect(model.state?.proxies.first?.health?.ok == true)
    }

    @Test @MainActor func testAllFallsBackInProcessWhenEdgeDoesNotAnswer() async throws {
        let (directory, store) = makeStore(checker: { _ in
            ProxyHealth(ok: true, latencyMs: 5, checkedAt: 1)
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.importProxies("http://proxy.example:8080")
        try writeEdgeConfig(in: directory)
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in nil }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .inApp)
        #expect(model.state?.proxies.first?.health?.ok == true)
    }

    @Test @MainActor func testAllSurfacesSkippedEdgeChecksAsANoticeWithoutWritingHealth() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://proxy.example:8080")
        let entryID = imported.proxies[0].id
        try writeEdgeConfig(in: directory)
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: [
                    entryID: .init(
                        ok: false,
                        checkedAt: Date().timeIntervalSince1970 * 1_000,
                        error: "no resolved proxy yet — this entry resolves at the next launch or connection",
                        deferred: true,
                        retryAfter: 60
                    ),
                ])
            }
        )
        model.load()

        await model.testAll()

        #expect(model.lastCheckRoute == .edge)
        #expect(model.state?.proxies.first?.health == nil)
        // A skip is a note, never the error alert.
        #expect(model.errorMessage == nil)
        #expect(model.checkNotice == "Skipped 1 check (proxy.example:8080): no resolved proxy yet — this entry resolves at the next launch or connection")
    }

    @Test @MainActor func testAllNoticeNamesEverySkippedEntry() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try store.addProxyScript(name: "Rotating", script: "return 'http://a.example:8080';")
        let second = try store.addProxyScript(name: "Backup", script: "return 'http://b.example:8080';")
        let entryIDs = [first.proxies[0].id, second.proxies[1].id]
        try writeEdgeConfig(in: directory)
        let model = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in nil },
            edgeCheckRunner: { _ in
                EdgeCheckResponse(results: Dictionary(uniqueKeysWithValues: entryIDs.map {
                    ($0, .init(
                        ok: false,
                        checkedAt: Date().timeIntervalSince1970 * 1_000,
                        error: "no resolved proxy yet",
                        deferred: true,
                        retryAfter: 60
                    ))
                }))
            }
        )
        model.load()

        await model.testAll()

        #expect(model.errorMessage == nil)
        #expect(model.checkNotice == "Skipped 2 checks (Rotating, Backup): no resolved proxy yet")
    }

    @Test @MainActor func refreshEdgeStatusTracksConfigurationAndLiveness() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEdgeConfig(in: directory)
        let status = EdgeStatusResponse(pid: 1, port: 1, mode: .off, launchedAt: 0)
        let live = ProxyAppModel(
            store: store,
            edgeStatusProvider: { _ in status },
            edgeCheckRunner: { _ in nil }
        )
        await live.refreshEdgeStatus()
        #expect(live.edgePanel == .running(status))

        let down = ProxyAppModel(store: store, edgeStatusProvider: { _ in nil }, edgeCheckRunner: { _ in nil })
        await down.refreshEdgeStatus()
        #expect(down.edgePanel == .notRunning)

        try FileManager.default.removeItem(at: directory.appending(path: "edge.json"))
        let unconfigured = ProxyAppModel(store: store, edgeStatusProvider: { _ in nil }, edgeCheckRunner: { _ in nil })
        await unconfigured.refreshEdgeStatus()
        #expect(unconfigured.edgePanel == .notConfigured)
    }

    @Test @MainActor func visibleModelRefreshPicksUpEdgeFreeUsageCooldowns() throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try store.importProxies("http://limited.example:8080\nhttp://available.example:8080")
        let model = ProxyAppModel(store: store)
        model.load()
        #expect(model.state?.autoEligibleProxies.count == 2)

        try FreeUsageLimitStore(configDirectory: directory)
            .flag(imported.proxies[0].id, until: Date().timeIntervalSince1970 + 3_600)
        model.refreshProxyStateFromDisk()

        #expect(model.state?.proxies[0].isFreeUsageLimited() == true)
        #expect(model.state?.autoEligibleProxies.map(\.id) == [imported.proxies[1].id])
    }

    @Test @MainActor func edgeAttributionGroupsTunnelsByPeer() async throws {
        let (directory, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeEdgeConfig(in: directory)
        let now = Date().timeIntervalSince1970
        let status = EdgeStatusResponse(
            pid: 10,
            port: 1,
            mode: .auto,
            counters: .init(tunnelsTotal: 3, tunnelsActive: 1),
            tunnels: [
                .init(clientPort: 1, peerPid: 100, peerName: "opencode", startedAt: now - 60, bytesDown: 1_000, active: true),
                .init(clientPort: 2, peerPid: 100, peerName: "opencode", startedAt: now - 600, endedAt: now - 500, bytesDown: 2_000, active: false),
                .init(clientPort: 3, peerPid: nil, peerName: nil, startedAt: now - 900, endedAt: now - 800, bytesDown: 4_000, active: false),
            ],
            launchedAt: now - 3_600
        )
        let model = ProxyAppModel(store: store, edgeStatusProvider: { _ in status }, edgeCheckRunner: { _ in nil })

        await model.refreshEdgeStatus()

        let attribution = model.edgeAttribution
        #expect(attribution.count == 2)
        #expect(attribution[0].pid == 100)
        #expect(attribution[0].tunnels == 2)
        #expect(attribution[0].activeTunnels == 1)
        #expect(attribution[0].bytesDown == 3_000)
        #expect(attribution[1].name == "Unknown process")
    }

    private func writeEdgeConfig(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = #"{"version":1,"port":57211}"#
        try Data(json.utf8).write(to: directory.appending(path: "edge.json"))
    }

    private func makeStore(
        checker: (@Sendable (String) async -> ProxyHealth)? = nil
    ) -> (URL, ProxyStore) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = checker.map { ProxyStore(configDirectory: directory, healthChecker: $0) }
            ?? ProxyStore(configDirectory: directory)
        return (directory, store)
    }

    private final class OpenCodeProbeRecorder: @unchecked Sendable {
        struct Record: Equatable {
            var entryID: String
            var proxyURL: String
            var port: Int
            var model: String
        }

        private let lock = NSLock()
        private var storedRecords: [Record] = []

        var records: [Record] {
            lock.lock()
            defer { lock.unlock() }
            return storedRecords
        }

        func record(entryID: String, proxyURL: String, port: Int, model: String) {
            lock.lock()
            storedRecords.append(Record(entryID: entryID, proxyURL: proxyURL, port: port, model: model))
            lock.unlock()
        }
    }

    private final class OpenCodeCommandRecorder: @unchecked Sendable {
        struct Invocation: Sendable {
            var command: String
            var environment: [String: String]
            var timeout: TimeInterval
        }

        private let lock = NSLock()
        private var storedInvocation: Invocation?

        var snapshot: Invocation? {
            lock.lock()
            defer { lock.unlock() }
            return storedInvocation
        }

        func record(command: String, environment: [String: String], timeout: TimeInterval) {
            lock.lock()
            storedInvocation = Invocation(command: command, environment: environment, timeout: timeout)
            lock.unlock()
        }
    }

    private actor ConcurrentProbeRecorder {
        private var active = 0
        private var maximum = 0
        private var startedIDs: Set<String> = []
        private var releasedIDs: Set<String> = []
        private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]

        func started(_ entryID: String) {
            active += 1
            maximum = max(maximum, active)
            startedIDs.insert(entryID)
            let ready = startWaiters.filter { startedIDs.count >= $0.count }
            startWaiters.removeAll { startedIDs.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }

        func waitUntilStarted(_ count: Int) async {
            guard startedIDs.count < count else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append((count, continuation))
            }
        }

        func waitForRelease(_ entryID: String) async {
            guard !releasedIDs.contains(entryID) else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters[entryID] = continuation
            }
        }

        func release(_ entryID: String) {
            releasedIDs.insert(entryID)
            releaseWaiters.removeValue(forKey: entryID)?.resume()
        }

        func finished() {
            active -= 1
        }

        func maximumConcurrent() -> Int { maximum }
    }
}
