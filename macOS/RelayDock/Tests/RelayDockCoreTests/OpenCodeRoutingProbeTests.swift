import Foundation
import Testing
@testable import RelayDockCore

struct OpenCodeRoutingProbeTests {
    private let config = EdgeConfigFile(port: 57_211)

    @Test func startupEnvironmentIsNotTrafficEvidence() {
        let environment = buildOpenCodeProxyEnvironment(proxyURL: config.proxyURL, base: [:])
        #expect(OpenCodeRoutingProbe.assess(environment: environment, edgeConfig: config) == .edgeEnvironment)
        #expect(OpenCodeRoutingProbe.assess(environment: [:], edgeConfig: config) == .missingProxy)
    }

    @Test func anotherProxyAndConflictingCaseVariantsAreReported() {
        var environment = buildOpenCodeProxyEnvironment(proxyURL: config.proxyURL, base: [:])
        environment["https_proxy"] = "http://user:secret@another.example:8080"
        #expect(OpenCodeRoutingProbe.assess(environment: environment, edgeConfig: config) == .otherProxy)
    }

    @Test func noProxyWildcardOutranksAnOtherwiseCorrectEnvironment() {
        let environment = buildOpenCodeProxyEnvironment(proxyURL: config.proxyURL, base: ["no_proxy": "*"])
        #expect(OpenCodeRoutingProbe.assess(environment: environment, edgeConfig: config) == .bypassAll)
    }

    @Test func missingConfigOrArbitraryBypassRulesStayUnverified() {
        let environment = buildOpenCodeProxyEnvironment(proxyURL: config.proxyURL, base: [:])
        #expect(OpenCodeRoutingProbe.assess(environment: environment, edgeConfig: nil) == .unverified)
        var bypass = environment
        bypass["NO_PROXY"] = "localhost,api.example.com"
        #expect(OpenCodeRoutingProbe.assess(environment: bypass, edgeConfig: config) == .unverified)
        #expect(OpenCodeRoutingProbe.assess(environment: ["HTTP_PROXY": config.proxyURL], edgeConfig: config) == .unverified)
    }

    @Test func onlyExplicitServerRolesAreClassified() {
        #expect(OpenCodeRoutingProbe.isServer(["opencode", "serve", "--service"]))
        #expect(OpenCodeRoutingProbe.isServer(["opencode", "serve", "--port", "4096"]))
        #expect(OpenCodeRoutingProbe.isServer(["opencode", "--standalone"]))
        #expect(!OpenCodeRoutingProbe.isServer(["opencode"]))
        #expect(!OpenCodeRoutingProbe.isServer(["opencode", "run", "serve"]))
        #expect(!OpenCodeRoutingProbe.isServer(["opencode", "service", "status"]))
        #expect(!OpenCodeRoutingProbe.isServer(["opencode", "serve", "--help"]))
    }

    @Test func kernelArgumentsKeepSpacesButDiscardNonProxySecrets() throws {
        let data = kernelData(
            argv: ["opencode", "serve", "--service"],
            environment: ["API_KEY=secret should never escape", "HTTPS_PROXY=http://127.0.0.1:57211", "NO_PROXY=localhost, 127.0.0.1"]
        )
        let parsed = try #require(OpenCodeRoutingProbe.parseArguments(data))
        #expect(parsed.argv == ["opencode", "serve", "--service"])
        #expect(parsed.proxyEnvironment == ["HTTPS_PROXY": config.proxyURL, "NO_PROXY": "localhost, 127.0.0.1"])
    }

    @Test func truncatedKernelArgumentsNeverAppearAsMissingProxy() {
        #expect(OpenCodeRoutingProbe.parseArguments(Data()) == nil)
        var data = kernelData(argv: ["opencode", "serve"], environment: [])
        data.removeLast(4)
        #expect(OpenCodeRoutingProbe.parseArguments(data) == nil)
        var truncatedEnvironment = kernelData(argv: ["opencode", "serve"], environment: ["HTTPS_PROXY=http://127.0.0.1:57211"])
        truncatedEnvironment.removeLast(4)
        #expect(OpenCodeRoutingProbe.parseArguments(truncatedEnvironment) == nil)
    }

    @Test func nativeInspectionReturnsOnlySanitizedProcessMetadata() async {
        let snapshot = await OpenCodeRoutingProbe.inspect(edgeConfig: config)
        #expect(snapshot.checkedAt > 0)
        #expect(Set(snapshot.servers.map(\.pid)).count == snapshot.servers.count)
        #expect(snapshot.servers.allSatisfy { $0.pid > 0 && $0.startedAt > 0 })
    }

    @Test func nativeInspectorFindsOwnedServersWithAndWithoutProxy() async throws {
        // A native test server named opencode, never the user's real service.
        // Only these owned processes are started/stopped by this test.
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "opencode")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-x", "c", "-", "-o", executable.path]
        let input = Pipe()
        compiler.standardInput = input
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        try input.fileHandleForWriting.write(contentsOf: Data("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".utf8))
        try input.fileHandleForWriting.close()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)

        for (environment, expected) in [
            (buildOpenCodeProxyEnvironment(proxyURL: config.proxyURL, base: [:]), OpenCodeRoutingSnapshot.Route.edgeEnvironment),
            ([:], OpenCodeRoutingSnapshot.Route.missingProxy),
        ] {
            let server = Process()
            server.executableURL = executable
            server.arguments = ["serve", "--service"]
            server.environment = environment
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            defer { server.terminate(); server.waitUntilExit() }
            let snapshot = await OpenCodeRoutingProbe.inspect(edgeConfig: config)
            let observed = try #require(snapshot.servers.first { $0.pid == server.processIdentifier })
            #expect(observed.route == expected)
        }
    }

    private func kernelData(argv: [String], environment: [String]) -> Data {
        var count = Int32(argv.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(Data("/a path with spaces/opencode\0\0\0".utf8))
        for value in argv + environment { data.append(Data((value + "\0").utf8)) }
        data.append(0)
        return data
    }
}
