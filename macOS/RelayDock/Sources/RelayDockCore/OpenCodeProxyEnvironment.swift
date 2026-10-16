import Foundation

/// Builds a child-process environment from the selected proxy policy.
/// A nil URL means explicit Off mode; callers must not use nil as a fallback
/// after `ProxyStore.selectForSpawn()` throws.
public func buildOpenCodeProxyEnvironment(
    proxyURL: String?,
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var environment = base
    environment["NO_PROXY"] = mergeNoProxy(base["NO_PROXY"])
    environment["no_proxy"] = mergeNoProxy(base["no_proxy"])
    let proxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    if let proxyURL {
        for key in proxyKeys { environment[key] = proxyURL }
    } else {
        for key in proxyKeys { environment.removeValue(forKey: key) }
    }
    // Do not leak credentials for a local OpenCode server into a child process.
    environment.removeValue(forKey: "OPENCODE_SERVER_PASSWORD")
    environment.removeValue(forKey: "OPENCODE_SERVER_USERNAME")
    return environment
}

private func mergeNoProxy(_ value: String?) -> String {
    var entries = (value ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    for local in ["localhost", "127.0.0.1"] where !entries.contains(local) { entries.append(local) }
    return entries.joined(separator: ",")
}
