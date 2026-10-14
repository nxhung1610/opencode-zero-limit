import Foundation
import Testing
@testable import RelayDockCore

struct ConsoleServiceTests {
    @Test @MainActor func listsOnlyOpenCodeConsoleMetadataWithoutCredentialValues() async throws {
        let stub = ConsoleTransportStub(responses: [jsonResponse(#"{"data":[{"id":"cred-a","integrationID":"opencode","label":"Team A","active":true,"key":"never-expose-this"},{"id":"other","integrationID":"github","label":"GitHub","active":false},{"id":"cred-b","integrationID":"opencode","active":false}]}"#)])
        let service = makeService(stub)

        let connections = try await service.connections()

        #expect(connections == [
            ConsoleConnection(id: "cred-a", label: "Team A", active: true),
            ConsoleConnection(id: "cred-b", label: "OpenCode Console account", active: false),
        ])
        #expect(stub.requests.first?.path == "/api/credential")
        #expect(stub.requests.first?.headers["Authorization"] == "Basic local-test-auth")
        #expect(!String(describing: connections).contains("never-expose-this"))
    }

    @Test @MainActor func loginPrefersDeviceOAuthValidatesHttpsAndEncodesAttemptIDs() async throws {
        let stub = ConsoleTransportStub(responses: [
            jsonResponse(#"{"data":{"methods":[{"id":"browser","type":"oauth"},{"id":"device","type":"oauth"},{"id":"password","type":"password"}]}}"#),
            jsonResponse(#"{"data":{"attemptID":"attempt/one","url":"https://auth.example/device","instructions":"Authorize this Mac","mode":"code"}}"#),
            jsonResponse(#"{"data":{"status":"pending"}}"#),
            jsonResponse(#"{"data":{"status":"complete"}}"#),
            ConsoleAPIResponse(statusCode: 204),
            ConsoleAPIResponse(statusCode: 404),
        ])
        let service = makeService(stub)

        let attempt = try await service.loginStart()
        #expect(attempt.attemptID == "attempt/one")
        #expect(attempt.url.absoluteString == "https://auth.example/device")
        #expect(attempt.mode == .code)
        #expect(try JSONSerialization.jsonObject(with: stub.requests[1].body!) as? [String: String] == ["methodID": "device"])
        #expect(try await service.loginStatus(attemptID: attempt.attemptID) == .pending)
        #expect(try await service.loginStatus(attemptID: attempt.attemptID) == .complete)
        try await service.loginComplete(attemptID: attempt.attemptID, code: "user-code")
        try await service.loginCancel(attemptID: attempt.attemptID)
        #expect(stub.requests[2].path == "/api/integration/opencode/connect/oauth/attempt%2Fone")
        #expect(stub.requests[4].path == "/api/integration/opencode/connect/oauth/attempt%2Fone/complete")
        #expect(stub.requests[4].method == "POST")
        #expect(stub.requests[5].method == "DELETE")
    }

    @Test @MainActor func refusesInsecureLoginURLsAndV1ConsoleAccounts() async throws {
        let insecure = ConsoleTransportStub(responses: [
            jsonResponse(#"{"methods":[{"id":"device","type":"oauth"}]}"#),
            jsonResponse(#"{"attemptID":"attempt","url":"http://auth.example/device"}"#),
        ])
        do {
            _ = try await makeService(insecure).loginStart()
            Issue.record("OpenCode sign-in URLs must be HTTPS")
        } catch {
            #expect(error as? ConsoleServiceError == .invalidResponse("OpenCode returned an invalid browser sign-in link"))
        }

        let v1Stub = ConsoleTransportStub(responses: [])
        let v1Service = ConsoleService(
            connectionProvider: { OpenCodeAPIConnection(port: 1234, majorVersion: 1) },
            transport: { request in try v1Stub.send(request) }
        )
        do {
            _ = try await v1Service.connections()
            Issue.record("Console OAuth credential management requires OpenCode v2")
        } catch {
            #expect(error as? ConsoleServiceError == .requiresV2)
        }
        #expect(v1Stub.requests.isEmpty)
    }

    @Test @MainActor func listsAndSwitchesV1OrganizationsUsingOpenCodeApi() async throws {
        let stub = ConsoleTransportStub(responses: [
            jsonResponse(#"{"data":{"orgs":[{"accountID":"account-a","accountEmail":"a@example.com","orgID":"org-a","orgName":"Personal","active":true},{"accountID":"account-b","accountEmail":"b@example.com","orgID":"org-b","orgName":"Team","active":false}]}}"#),
            ConsoleAPIResponse(statusCode: 204),
        ])
        let service = ConsoleService(
            connectionProvider: { OpenCodeAPIConnection(port: 1234, majorVersion: 1, headers: ["Authorization": "Basic local-test-auth"]) },
            transport: { request in try stub.send(request) }
        )

        let organizations = try await service.organizations()
        try await service.switchOrganization(accountID: "account-b", orgID: "org-b")

        #expect(organizations == [
            ConsoleOrganization(accountID: "account-a", accountEmail: "a@example.com", orgID: "org-a", orgName: "Personal", active: true),
            ConsoleOrganization(accountID: "account-b", accountEmail: "b@example.com", orgID: "org-b", orgName: "Team", active: false),
        ])
        #expect(stub.requests[0].path == "/experimental/console/orgs")
        #expect(stub.requests[0].headers["Authorization"] == "Basic local-test-auth")
        #expect(stub.requests[1].path == "/experimental/console/switch")
        #expect(stub.requests[1].method == "POST")
        #expect(try JSONSerialization.jsonObject(with: stub.requests[1].body!) as? [String: String] == ["accountID": "account-b", "orgID": "org-b"])
    }

    @Test @MainActor func validatesCredentialOwnershipBeforeActivateOrRemove() async throws {
        let credentials = jsonResponse(#"{"data":[{"id":"credential/one","integrationID":"opencode","label":"Personal","active":false,"key":"secret"},{"id":"elsewhere","integrationID":"github","label":"not mine"}]}"#)
        let stub = ConsoleTransportStub(responses: [
            credentials,
            ConsoleAPIResponse(statusCode: 204),
            credentials,
            ConsoleAPIResponse(statusCode: 204),
            credentials,
        ])
        let service = makeService(stub)

        _ = try await service.activate("credential/one")
        #expect(try await service.remove("credential/one") == "Removed Personal")
        #expect(stub.requests[1].path == "/api/credential/credential%2Fone/activate")
        #expect(stub.requests[3].path == "/api/credential/credential%2Fone")

        do {
            _ = try await service.remove("elsewhere")
            Issue.record("Must not remove a credential owned by another integration")
        } catch {
            #expect(error as? ConsoleServiceError == .invalidResponse("OpenCode Console credential not found"))
        }
    }

    @MainActor
    private func makeService(_ stub: ConsoleTransportStub) -> ConsoleService {
        ConsoleService(
            connectionProvider: { OpenCodeAPIConnection(port: 42_123, majorVersion: 2, headers: ["Authorization": "Basic local-test-auth"]) },
            transport: { request in try stub.send(request) }
        )
    }

    private func jsonResponse(_ string: String) -> ConsoleAPIResponse {
        ConsoleAPIResponse(statusCode: 200, body: Data(string.utf8))
    }
}

@MainActor
private final class ConsoleTransportStub {
    var responses: [ConsoleAPIResponse]
    var requests: [ConsoleAPIRequest] = []

    init(responses: [ConsoleAPIResponse]) {
        self.responses = responses
    }

    func send(_ request: ConsoleAPIRequest) throws -> ConsoleAPIResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ConsoleServiceError.requestFailed("Unexpected OpenCode API request")
        }
        return responses.removeFirst()
    }
}
