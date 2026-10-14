import Foundation
import Testing
@testable import RelayDockCore

struct OpenCodeManagerTests {
    @Test func proxyEnvironmentPreservesNoProxyAndIgnoresInheritedProxyWhenOff() {
        let base = [
            "HTTP_PROXY": "http://inherited.example:8080",
            "HTTPS_PROXY": "http://inherited.example:8080",
            "no_proxy": "internal.example",
            "NO_PROXY": "localhost,example.test",
            "OPENCODE_SERVER_PASSWORD": "stale-secret",
        ]
        let direct = buildOpenCodeProxyEnvironment(proxyURL: nil, base: base)
        #expect(direct["HTTP_PROXY"] == nil)
        #expect(direct["HTTPS_PROXY"] == nil)
        #expect(direct["NO_PROXY"] == "localhost,example.test,127.0.0.1")
        #expect(direct["no_proxy"] == "internal.example,localhost,127.0.0.1")
        #expect(direct["OPENCODE_SERVER_PASSWORD"] == nil)

        let routed = buildOpenCodeProxyEnvironment(proxyURL: "socks5://proxy.example:1080", base: base)
        #expect(routed["ALL_PROXY"] == "socks5://proxy.example:1080")
        #expect(routed["all_proxy"] == "socks5://proxy.example:1080")
        #expect(routed["HTTP_PROXY"] == "socks5://proxy.example:1080")
    }

    @Test func resolvesConfiguredAndPathBinaries() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "opencode")
        try Data("#!/bin/sh\necho opencode 2.1.0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        #expect(resolveOpenCodeBinary(configured: binary.path, environment: ["HOME": directory.path]) == binary.path)
        #expect(resolveOpenCodeBinary(environment: ["HOME": directory.path, "PATH": directory.path]) == binary.path)
    }

    @Test @MainActor func startsAndStopsTheManagedOpenCodeV2Process() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "mock-opencode")
        let marker = directory.appending(path: "serve-started")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "opencode 2.4.6"
          exit 0
        fi
        echo started >> "\(marker.path)"
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let settings = SettingsStore(configDirectory: directory)
        try settings.save(AppSettings(autoStart: false, opencodeBin: binary.path))

        let manager = OpenCodeManager(
            settings: settings,
            proxySelector: { _ in "http://proxy.example:8080" },
            healthProbe: { port, major, password in
                #expect(port > 0)
                #expect(major == 2)
                #expect(password != nil)
                return "2.4.6"
            }
        )

        let started = await manager.start()
        #expect(started.running)
        #expect(started.healthy)
        #expect(started.version == "2.4.6")
        #expect(manager.getCLIMajorVersion() == 2)
        #expect(manager.apiHeaders()["Authorization"]?.hasPrefix("Basic ") == true)
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let stopped = await manager.stop()
        #expect(!stopped.running)
        #expect(manager.getPort() == nil)
        #expect(manager.apiHeaders().isEmpty)
    }

    @Test @MainActor func activeConsoleAccountChangeRestartsOnlyWhenProxyBindingChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "mock-opencode")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "opencode 2.4.6"
          exit 0
        fi
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let settings = SettingsStore(configDirectory: directory)
        try settings.save(AppSettings(autoStart: false, opencodeBin: binary.path))

        let manager = OpenCodeManager(
            settings: settings,
            proxySelector: { accountID in
                accountID == "credential-b" ? "http://proxy-b.example:8080" : "http://proxy-a.example:8080"
            },
            healthProbe: { _, _, _ in "2.4.6" }
        )

        #expect((await manager.start()).healthy)
        let originalPort = manager.getPort()
        #expect((await manager.activeConsoleAccountDidChange("credential-b")).healthy)
        let reboundPort = manager.getPort()
        #expect(reboundPort != nil && reboundPort != originalPort)

        #expect((await manager.activeConsoleAccountDidChange("credential-b")).healthy)
        #expect(manager.getPort() == reboundPort)
        _ = await manager.stop()
    }

    @Test @MainActor func refusesToSpawnWhenProxySelectionFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appending(path: "mock-opencode")
        let marker = directory.appending(path: "serve-started")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "opencode 2.4.6"; exit 0; fi
        echo started >> "\(marker.path)"
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let settings = SettingsStore(configDirectory: directory)
        try settings.save(AppSettings(autoStart: false, opencodeBin: binary.path))
        let manager = OpenCodeManager(settings: settings, proxySelector: { _ in
            throw ProxyStoreError.autoHasNoEnabledProxy
        })

        let status = await manager.start()
        #expect(!status.running)
        #expect(status.error?.contains("at least one enabled proxy") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
