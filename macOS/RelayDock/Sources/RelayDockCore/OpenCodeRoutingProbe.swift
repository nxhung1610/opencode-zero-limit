import Darwin
import Foundation

/// Startup environment, not proof of model traffic. No credentials, arguments,
/// or raw environment leave the inspector. Only native, same-user OpenCode
/// servers (`serve` / `--standalone`) are in scope; remote/embedded SDK servers
/// cannot be identified by this probe.
public struct OpenCodeRoutingSnapshot: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        case edgeEnvironment
        case missingProxy
        case otherProxy
        case bypassAll
        case unverified
    }

    public struct Server: Equatable, Sendable {
        public var pid: Int32
        public var startedAt: Double
        public var route: Route

        public init(pid: Int32, startedAt: Double, route: Route) {
            self.pid = pid
            self.startedAt = startedAt
            self.route = route
        }
    }

    public var servers: [Server]
    public var inspectionIncomplete: Bool
    public var checkedAt: Double

    public init(
        servers: [Server] = [],
        inspectionIncomplete: Bool = false,
        checkedAt: Double = Date().timeIntervalSince1970
    ) {
        self.servers = servers
        self.inspectionIncomplete = inspectionIncomplete
        self.checkedAt = checkedAt
    }

    public var affectedServers: [Server] {
        servers.filter { [.missingProxy, .otherProxy, .bypassAll].contains($0.route) }
    }

    public var isUnverified: Bool {
        inspectionIncomplete || servers.contains { $0.route == .unverified }
    }
}

public enum OpenCodeRoutingProbe {
    static let proxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    private static let inspectedKeys = Set(proxyKeys + ["NO_PROXY", "no_proxy"])

    public static func inspect(edgeConfig: EdgeConfigFile?) async -> OpenCodeRoutingSnapshot {
        await Task.detached(priority: .utility) { scan(edgeConfig: edgeConfig) }.value
    }

    static func assess(environment: [String: String], edgeConfig: EdgeConfigFile?) -> OpenCodeRoutingSnapshot.Route {
        let bypass = ["NO_PROXY", "no_proxy"].flatMap { (environment[$0] ?? "").split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if bypass.contains("*") { return .bypassAll }
        let values = proxyKeys.compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return .missingProxy }
        guard let edgeConfig else { return .unverified }
        let ports = Set([edgeConfig.port] + edgeConfig.listeners.map(\.port))
        guard values.allSatisfy({ value in
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "http",
                  let host = url.host?.lowercased(), ["127.0.0.1", "localhost"].contains(host),
                  let port = url.port, ports.contains(port), url.user == nil, url.password == nil,
                  url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return false }
            return true
        }) else { return .otherProxy }
        // Do not certify HTTPS from an HTTP-only variable or arbitrary bypass
        // rules. Runtime precedence and provider destinations may differ.
        let hasHTTPS = ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"].contains {
            !(environment[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let local = Set(["localhost", "127.0.0.1", "::1", "[::1]"])
        guard hasHTTPS, bypass.allSatisfy({ $0.isEmpty || local.contains($0.lowercased()) }) else { return .unverified }
        return .edgeEnvironment
    }

    struct Arguments {
        var argv: [String]
        var proxyEnvironment: [String: String]
    }

    /// KERN_PROCARGS2 is NUL-delimited; splitting `ps eww` on spaces corrupts
    /// argument and environment values. Retain only proxy variables.
    static func parseArguments(_ data: Data) -> Arguments? {
        let bytes = [UInt8](data)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 16_384 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(decoding: bytes[cursor..<end], as: UTF8.self)
        }
        guard nextString() != nil else { return nil } // executable path
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            argv.append(argument)
        }
        var environment: [String: String] = [:]
        while cursor < bytes.count {
            guard let item = nextString() else { return nil }
            if item.isEmpty { break }
            guard let separator = item.firstIndex(of: "=") else { continue }
            let key = String(item[..<separator])
            if inspectedKeys.contains(key) { environment[key] = String(item[item.index(after: separator)...]) }
        }
        return Arguments(argv: argv, proxyEnvironment: environment)
    }

    static func isServer(_ argv: [String]) -> Bool {
        let arguments = argv.dropFirst()
        guard !arguments.contains("--help"), !arguments.contains("-h") else { return false }
        return arguments.first == "serve" || arguments.contains("--standalone")
    }

    private static func scan(edgeConfig: EdgeConfigFile?) -> OpenCodeRoutingSnapshot {
        // proc_listpids returns byte counts (unlike proc_listallpids).
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { return .init(inspectionIncomplete: true) }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return .init(inspectionIncomplete: true) }
        var snapshot = OpenCodeRoutingSnapshot(inspectionIncomplete: Int(filled) >= capacity * MemoryLayout<pid_t>.stride)
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 && pid != getpid() {
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let processName = String(decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard ["opencode", "opencode.exe"].contains(processName.lowercased()) else { continue }

            var before = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride else {
                if kill(pid, 0) == 0 { snapshot.inspectionIncomplete = true }
                continue
            }
            guard before.pbi_uid == getuid() else { continue }
            guard let arguments = readArguments(pid) else {
                if kill(pid, 0) == 0 { snapshot.inspectionIncomplete = true }
                continue
            }
            guard isServer(arguments.argv) else { continue }
            var after = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
                  before.pbi_start_tvsec == after.pbi_start_tvsec,
                  before.pbi_start_tvusec == after.pbi_start_tvusec else { continue }
            snapshot.servers.append(.init(
                pid: pid,
                startedAt: Double(before.pbi_start_tvsec) + Double(before.pbi_start_tvusec) / 1_000_000,
                route: assess(environment: arguments.proxyEnvironment, edgeConfig: edgeConfig)
            ))
        }
        snapshot.servers.sort { $0.pid < $1.pid }
        return snapshot
    }

    private static func readArguments(_ pid: pid_t) -> Arguments? {
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Data(bytes.prefix(size)))
    }
}
