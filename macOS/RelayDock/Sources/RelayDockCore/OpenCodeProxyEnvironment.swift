import Foundation

/// Builds a child-process environment from the selected proxy policy.
/// A nil URL means explicit Off mode; callers must not use nil as a fallback
/// after `ProxyStore.selectForSpawn()` throws.
public func buildOpenCodeProxyEnvironment(
    proxyURL: String?,
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var environment = base
    // Only loopback may bypass Edge. Inheriting a broader NO_PROXY (including
    // `*`) would send provider traffic around the proxy, defeating routing and
    // accounting without the user seeing it.
    environment["NO_PROXY"] = loopbackNoProxy
    environment["no_proxy"] = loopbackNoProxy
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

private let loopbackNoProxy = "localhost,127.0.0.1"
