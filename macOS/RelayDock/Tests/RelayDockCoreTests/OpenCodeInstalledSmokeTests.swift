import Foundation
import Testing
@testable import RelayDockCore

struct OpenCodeInstalledSmokeTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["OPENCODE_BIN"]?.isEmpty == false,
        "Set OPENCODE_BIN or run scripts/smoke-opencode-macos.sh"
    ))
    @MainActor func installedOpenCodeServesItsVersionSpecificApiAndEventStream() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["OPENCODE_BIN"])
        let version = try readVersion(binary: binary)
        guard version.major == 1 || version.major == 2 else {
            Issue.record("Unsupported OpenCode CLI for smoke check: \(version.text)")
            return
        }

        let configDirectory = FileManager.default.temporaryDirectory
            .appending(path: "relaydock-opencode-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        let settings = SettingsStore(configDirectory: configDirectory)
        let manager = OpenCodeManager(settings: settings, proxySelector: { _ in nil })
        let started = await manager.start()
        guard started.healthy, let port = started.port else {
            _ = await manager.stop()
            Issue.record("OpenCode v2 did not become healthy: \(started.error ?? "unknown startup error")")
            return
        }

        let service = ConsoleService(manager: manager)
        var serviceError: Error?
        do {
            if version.major == 2 {
                let connections = try await service.connections()
                #expect(connections.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty })
                #expect(!String(describing: connections).contains("access_token"))
            } else {
                let organizations = try await service.organizations()
                #expect(organizations.allSatisfy { !$0.accountID.isEmpty && !$0.orgID.isEmpty })
            }
        } catch {
            serviceError = error
        }

        let eventPath = version.major == 2 ? "/api/event" : "/event"
        let eventResponse = await eventStreamResponse(port: port, path: eventPath, headers: manager.apiHeaders())
        let stopped = await manager.stop()
        try? FileManager.default.removeItem(at: configDirectory)

        #expect(serviceError == nil, "Console credential metadata request failed: \(serviceError?.localizedDescription ?? "")")
        #expect(eventResponse.statusCode == 200)
        #expect(eventResponse.contentType?.contains("text/event-stream") == true)
        #expect(!stopped.running)
    }

    private func readVersion(binary: String) throws -> (text: String, major: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
              let firstDigit = text.firstIndex(where: \.isNumber),
              let end = text[firstDigit...].firstIndex(where: { !$0.isNumber }) else {
            throw SmokeError.invalidVersion(text)
        }
        let major = Int(text[firstDigit..<end]) ?? 0
        return (text, major)
    }

    private func eventStreamResponse(port: Int, path: String, headers: [String: String]) async -> (statusCode: Int, contentType: String?) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        guard let url = components.url else { return (0, nil) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { return (0, nil) }
            return (response.statusCode, response.value(forHTTPHeaderField: "Content-Type"))
        } catch {
            return (0, nil)
        }
    }

    private enum SmokeError: Error {
        case invalidVersion(String)
    }
}
