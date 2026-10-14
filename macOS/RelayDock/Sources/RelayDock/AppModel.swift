import Foundation
import Observation
import RelayDockCore

enum AppSection: String, CaseIterable, Identifiable {
    case accounts
    case usage
    case proxies
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .usage: "Usage"
        case .proxies: "Proxies"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .usage: "chart.bar.xaxis"
        case .proxies: "network"
        case .settings: "gearshape"
        }
    }
}

private enum ManagedServerOperation {
    case starting
    case stopping
    case restarting
}

@Observable
@MainActor
final class AppModel {
    var selection: AppSection = .accounts
    var settings: AppSettings
    var saveError: String?
    var proxyState: ProxyState
    var proxyError: String?
    var checkingProxies = false
    var serverStatus: OpenCodeStatus = .stopped
    var serverBusy = false
    var consoleConnections: [ConsoleConnection] = []
    var accountsLoading = false
    var accountsBusy = false
    var accountError: String?
    var accountNotice: String?
    var loginAttempt: ConsoleLoginAttempt?
    var loginCode = ""
    var usageDays = 30
    var usageSummary: UsageSummary?
    var usageLoading = false
    var usageError: String?
    var quotaEvent: QuotaEvent?

    private let store: SettingsStore
    private let proxyStore: ProxyStore
    private let openCodeManager: OpenCodeManager
    private let consoleService: ConsoleService
    private let usageReader: UsageReader
    private let quotaWatcher: QuotaWatcher
    private var usageRequestID: UUID?
    private var serverOperation: ManagedServerOperation?
    private var restartRequestedAfterOperation = false

    init(store: SettingsStore = SettingsStore(), proxyStore: ProxyStore = ProxyStore()) {
        self.store = store
        self.proxyStore = proxyStore
        let usageReader = UsageReader()
        self.usageReader = usageReader
        let manager = OpenCodeManager(settings: store, proxySelector: { accountID in
            try proxyStore.selectForSpawn(accountID: accountID ?? usageReader.activeAccountID())
        })
        self.openCodeManager = manager
        let consoleService = ConsoleService(manager: manager)
        self.consoleService = consoleService
        let quotaWatcher = QuotaWatcher(manager: manager, settings: store, consoleService: consoleService)
        self.quotaWatcher = quotaWatcher
        self.settings = store.load()
        do {
            self.proxyState = try proxyStore.load()
            self.proxyError = nil
        } catch {
            self.proxyState = .defaults
            self.proxyError = error.localizedDescription
        }
        quotaWatcher.onEvent = { [weak self] event in
            self?.quotaEvent = event
            if event.rotatedTo != nil {
                Task { await self?.refreshConsoleConnections() }
            }
        }
    }

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        let previousBinary = settings.opencodeBin
        var changed = settings
        update(&changed)
        do {
            try store.save(changed)
            settings = changed
            saveError = nil
            if previousBinary != changed.opencodeBin && (serverStatus.running || serverBusy) {
                Task { await restartOpenCode() }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func clearSaveError() {
        saveError = nil
    }

    func refreshProxies() {
        do {
            proxyState = try proxyStore.load()
            proxyError = nil
        } catch {
            proxyError = error.localizedDescription
        }
    }

    func importProxies(_ text: String) {
        performProxyMutation { try proxyStore.importProxies(text) }
    }

    func setProxyMode(_ mode: ProxyMode) {
        let manualID = mode == .manual
            ? proxyState.manualId ?? proxyState.proxies.first(where: \.enabled)?.id
            : nil
        guard mode != .manual || manualID != nil else {
            proxyError = "Import at least one proxy before choosing Manual mode."
            return
        }
        performProxyMutation { try proxyStore.setMode(mode, manualId: manualID) }
    }

    func chooseManualProxy(_ id: String) {
        performProxyMutation { try proxyStore.setMode(.manual, manualId: id) }
    }

    func setProxyEnabled(_ id: String, enabled: Bool) {
        performProxyMutation { try proxyStore.setEnabled(id, enabled: enabled) }
    }

    func removeProxy(_ id: String) {
        performProxyMutation { try proxyStore.remove(id) }
    }

    func selectedProxyForSpawn(accountID: String = "default") throws -> String? {
        try proxyStore.selectForSpawn(accountID: accountID)
    }

    func applicationDidLaunch() async {
        guard settings.autoStart else { return }
        await startOpenCode()
    }

    func refreshOpenCodeStatus() async {
        serverStatus = await openCodeManager.status()
        if serverStatus.healthy { quotaWatcher.start() }
        else { await quotaWatcher.stop() }
    }

    func startOpenCode() async {
        guard !serverBusy else { return }
        serverBusy = true
        serverOperation = .starting
        serverStatus = await openCodeManager.start()
        if serverStatus.healthy { quotaWatcher.start() }
        serverBusy = false
        serverOperation = nil
        await restartIfRequested()
    }

    func stopOpenCode() async {
        guard !serverBusy else { return }
        restartRequestedAfterOperation = false
        serverBusy = true
        serverOperation = .stopping
        await quotaWatcher.stop()
        serverStatus = await openCodeManager.stop()
        serverBusy = false
        serverOperation = nil
    }

    func restartOpenCode() async {
        if serverBusy {
            if serverOperation != .stopping { restartRequestedAfterOperation = true }
            return
        }
        guard serverStatus.running else { return }
        serverBusy = true
        serverOperation = .restarting
        await quotaWatcher.stop()
        serverStatus = await openCodeManager.restart()
        if serverStatus.healthy { quotaWatcher.start() }
        serverBusy = false
        serverOperation = nil
        await restartIfRequested()
    }

    func terminateManagedProcess() {
        openCodeManager.terminateImmediately()
    }

    var supportsConsoleAccounts: Bool {
        guard serverStatus.healthy, let version = serverStatus.version else { return false }
        let majorDigits = version.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return Int(majorDigits) == 2
    }

    var accountServerKey: String {
        "\(serverStatus.healthy)-\(serverStatus.version ?? "unknown")"
    }

    func refreshConsoleConnections() async {
        guard serverStatus.healthy else {
            consoleConnections = []
            accountsLoading = false
            loginAttempt = nil
            loginCode = ""
            return
        }
        guard supportsConsoleAccounts else {
            consoleConnections = []
            accountsLoading = false
            accountError = nil
            loginAttempt = nil
            loginCode = ""
            return
        }
        accountsLoading = true
        do {
            consoleConnections = try await consoleService.connections()
            if !serverBusy, let active = consoleConnections.first(where: \.active) {
                serverBusy = true
                serverOperation = .restarting
                serverStatus = await openCodeManager.activeConsoleAccountDidChange(active.id)
                serverBusy = false
                serverOperation = nil
                if !serverStatus.healthy, let error = serverStatus.error {
                    accountError = error
                    accountsLoading = false
                    await restartIfRequested()
                    return
                }
                await restartIfRequested()
            }
            accountError = nil
        } catch {
            consoleConnections = []
            accountError = error.localizedDescription
        }
        accountsLoading = false
    }

    func startConsoleLogin() async {
        guard !accountsBusy else { return }
        accountsBusy = true
        accountError = nil
        accountNotice = nil
        do {
            loginAttempt = try await consoleService.loginStart()
            loginCode = ""
            accountNotice = "Finish authorization in the browser. OpenCode saves the credential locally."
        } catch {
            accountError = error.localizedDescription
        }
        accountsBusy = false
    }

    func cancelConsoleLogin() async {
        guard !accountsBusy, let attempt = loginAttempt else { return }
        accountsBusy = true
        do {
            try await consoleService.loginCancel(attemptID: attempt.attemptID)
            loginAttempt = nil
            loginCode = ""
            accountNotice = "Sign-in cancelled."
            accountError = nil
        } catch {
            accountError = error.localizedDescription
        }
        accountsBusy = false
    }

    func completeConsoleLogin() async {
        guard !accountsBusy, let attempt = loginAttempt else { return }
        accountsBusy = true
        do {
            try await consoleService.loginComplete(attemptID: attempt.attemptID, code: loginCode)
            accountNotice = "Code submitted. Waiting for OpenCode to save the Console credential locally…"
            accountError = nil
        } catch {
            accountError = error.localizedDescription
        }
        accountsBusy = false
    }

    func pollConsoleLogin() async {
        guard let attempt = loginAttempt else { return }
        do {
            switch try await consoleService.loginStatus(attemptID: attempt.attemptID) {
            case .pending:
                break
            case .complete:
                loginAttempt = nil
                loginCode = ""
                accountNotice = "OpenCode Console connected. The credential is saved in OpenCode’s local database."
                accountError = nil
                await refreshConsoleConnections()
            case .failed(let message), .expired(let message):
                loginAttempt = nil
                loginCode = ""
                accountError = message
            }
        } catch {
            accountError = "Could not check sign-in status: \(error.localizedDescription)"
        }
    }

    func activateConsoleConnection(_ connection: ConsoleConnection) async {
        guard !accountsBusy, !serverBusy, !connection.active else { return }
        accountsBusy = true
        serverBusy = true
        serverOperation = .restarting
        accountNotice = "Activating \(connection.label)…"
        accountError = nil
        do {
            serverStatus = try await consoleService.activate(connection.id)
            if serverStatus.healthy {
                await refreshConsoleConnections()
                if accountError == nil {
                    accountNotice = "\(connection.label) is now the active OpenCode Console account."
                } else {
                    accountNotice = nil
                }
            } else {
                accountNotice = nil
                accountError = serverStatus.error ?? "OpenCode stopped after activating the account."
            }
        } catch {
            accountNotice = nil
            accountError = error.localizedDescription
        }
        serverBusy = false
        serverOperation = nil
        accountsBusy = false
        await restartIfRequested()
    }

    func removeConsoleConnection(_ connection: ConsoleConnection) async {
        guard !accountsBusy, !serverBusy else { return }
        accountsBusy = true
        accountError = nil
        do {
            accountNotice = try await consoleService.remove(connection.id)
            await refreshConsoleConnections()
        } catch {
            accountNotice = nil
            accountError = error.localizedDescription
        }
        accountsBusy = false
    }

    func refreshUsage() async {
        let requestID = UUID()
        usageRequestID = requestID
        usageLoading = true
        do {
            let reader = usageReader
            let days = usageDays
            let summary = try await Task.detached(priority: .utility) {
                try reader.summary(days: days)
            }.value
            guard usageRequestID == requestID else { return }
            usageSummary = summary
            usageError = nil
        } catch {
            guard usageRequestID == requestID else { return }
            usageSummary = nil
            usageError = error.localizedDescription
        }
        usageLoading = false
    }

    func clearProxyError() {
        proxyError = nil
    }

    func checkAllProxies() async {
        guard !checkingProxies else { return }
        checkingProxies = true
        do {
            proxyState = try await proxyStore.checkAll()
            proxyError = nil
        } catch {
            proxyError = error.localizedDescription
        }
        checkingProxies = false
    }

    private func performProxyMutation(_ operation: () throws -> ProxyState) {
        do {
            proxyState = try operation()
            proxyError = nil
            if serverStatus.running || serverBusy { Task { await restartOpenCode() } }
        } catch {
            proxyError = error.localizedDescription
        }
    }

    private func restartIfRequested() async {
        guard restartRequestedAfterOperation else { return }
        restartRequestedAfterOperation = false
        if serverStatus.running {
            await restartOpenCode()
        } else {
            await startOpenCode()
        }
    }
}
