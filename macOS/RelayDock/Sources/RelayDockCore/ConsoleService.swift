import Foundation

public struct ConsoleConnection: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var active: Bool

    public init(id: String, label: String, active: Bool) {
        self.id = id
        self.label = label
        self.active = active
    }
}

public struct ConsoleOrganization: Equatable, Identifiable, Sendable {
    public var accountID: String
    public var accountEmail: String
    public var orgID: String
    public var orgName: String
    public var active: Bool

    public var id: String { "\(accountID):\(orgID)" }

    public init(accountID: String, accountEmail: String, orgID: String, orgName: String, active: Bool) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.orgID = orgID
        self.orgName = orgName
        self.active = active
    }
}

public enum ConsoleLoginMode: String, Sendable {
    case automatic = "auto"
    case code
}

public struct ConsoleLoginAttempt: Equatable, Sendable {
    public var attemptID: String
    public var url: URL
    public var instructions: String
    public var mode: ConsoleLoginMode

    public init(attemptID: String, url: URL, instructions: String, mode: ConsoleLoginMode) {
        self.attemptID = attemptID
        self.url = url
        self.instructions = instructions
        self.mode = mode
    }
}

public enum ConsoleLoginStatus: Equatable, Sendable {
    case pending
    case complete
    case failed(String)
    case expired(String)
}

public struct OpenCodeAPIConnection: Equatable, Sendable {
    public var port: Int
    public var majorVersion: Int
    public var headers: [String: String]

    public init(port: Int, majorVersion: Int, headers: [String: String] = [:]) {
        self.port = port
        self.majorVersion = majorVersion
        self.headers = headers
    }
}

public struct ConsoleAPIRequest: Sendable {
    public var port: Int
    public var path: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(port: Int, path: String, method: String, headers: [String: String], body: Data?) {
        self.port = port
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct ConsoleAPIResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data = Data()) {
        self.statusCode = statusCode
        self.body = body
    }
}

public typealias ConsoleAPITransport = @MainActor @Sendable (ConsoleAPIRequest) async throws -> ConsoleAPIResponse
public typealias ConsoleAPIConnectionProvider = @MainActor @Sendable () -> OpenCodeAPIConnection?

public enum ConsoleServiceError: LocalizedError, Equatable {
    case serverNotRunning
    case requiresV2
    case requiresV1
    case invalidResponse(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning: "OpenCode server is not running. Start it from the toolbar first."
        case .requiresV2: "Console account management requires OpenCode CLI v2."
        case .requiresV1: "Organization switching requires OpenCode CLI v1."
        case .invalidResponse(let message): message
        case .requestFailed(let message): message
        }
    }
}

@MainActor
public final class ConsoleService {
    private static let integrationID = "opencode"
    private let manager: OpenCodeManager?
    private let connectionProvider: ConsoleAPIConnectionProvider
    private let transport: ConsoleAPITransport?

    public init(manager: OpenCodeManager) {
        self.manager = manager
        connectionProvider = {
            guard let port = manager.getPort(), let majorVersion = manager.getCLIMajorVersion() else { return nil }
            return OpenCodeAPIConnection(port: port, majorVersion: majorVersion, headers: manager.apiHeaders())
        }
        transport = nil
    }

    init(connectionProvider: @escaping ConsoleAPIConnectionProvider, transport: @escaping ConsoleAPITransport) {
        manager = nil
        self.connectionProvider = connectionProvider
        self.transport = transport
    }

    public func connections() async throws -> [ConsoleConnection] {
        let credentials = try await credentialRecords()
        return credentials.compactMap { credential in
            guard credential["integrationID"] as? String == Self.integrationID,
                  let id = credential["id"] as? String else { return nil }
            let rawLabel = (credential["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConsoleConnection(id: id, label: rawLabel?.isEmpty == false ? rawLabel! : "OpenCode Console account", active: credential["active"] as? Bool == true)
        }
    }

    public func organizations() async throws -> [ConsoleOrganization] {
        try requireV1()
        let value = try await apiJSON(path: "/experimental/console/orgs")
        guard let record = value as? [String: Any], let rawOrganizations = record["orgs"] as? [[String: Any]] else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode Console organization response")
        }
        return rawOrganizations.compactMap { organization in
            guard let accountID = organization["accountID"] as? String,
                  let accountEmail = organization["accountEmail"] as? String,
                  let orgID = organization["orgID"] as? String,
                  let orgName = organization["orgName"] as? String else { return nil }
            return ConsoleOrganization(
                accountID: accountID,
                accountEmail: accountEmail,
                orgID: orgID,
                orgName: orgName,
                active: organization["active"] as? Bool == true
            )
        }
    }

    public func switchOrganization(accountID: String, orgID: String) async throws {
        try requireV1()
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.count <= 256,
              !orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              orgID.count <= 256 else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode Console organization ID")
        }
        let body = try JSONSerialization.data(withJSONObject: ["accountID": accountID, "orgID": orgID])
        try await apiRequest(path: "/experimental/console/switch", method: "POST", body: body, accepted: 200..<300)
    }

    public func loginStart() async throws -> ConsoleLoginAttempt {
        try requireV2()
        var integration: Any = NSNull()
        for attempt in 0..<12 {
            do {
                integration = try await apiJSON(path: "/api/integration/\(Self.integrationID)")
                break
            } catch let error as ConsoleServiceError {
                if case .requestFailed(let message) = error, message.contains("IntegrationNotFoundError"), attempt < 11 {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                throw error
            }
        }
        guard let integrationObject = integration as? [String: Any],
              let methods = integrationObject["methods"] as? [[String: Any]] else {
            throw ConsoleServiceError.invalidResponse("OpenCode Console integration is unavailable")
        }
        let oauthMethods = methods.filter { $0["type"] as? String == "oauth" }
        let method = oauthMethods.first(where: { $0["id"] as? String == "device" }) ?? oauthMethods.first
        guard let methodID = method?["id"] as? String else {
            throw ConsoleServiceError.invalidResponse("OpenCode Console does not offer browser sign-in")
        }
        let body = try JSONSerialization.data(withJSONObject: ["methodID": methodID])
        let attempt = try await apiJSON(path: "/api/integration/\(Self.integrationID)/connect/oauth", method: "POST", body: body)
        guard let record = attempt as? [String: Any],
              let attemptID = (record["attemptID"] as? String) ?? (record["id"] as? String),
              attemptID.count <= 256,
              let rawURL = record["url"] as? String,
              let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw ConsoleServiceError.invalidResponse("OpenCode returned an invalid browser sign-in link")
        }
        let mode = (record["mode"] as? String) == "code" ? ConsoleLoginMode.code : .automatic
        let instructions = record["instructions"] as? String ?? "Complete sign-in in your browser."
        return ConsoleLoginAttempt(attemptID: attemptID, url: url, instructions: instructions, mode: mode)
    }

    public func loginStatus(attemptID: String) async throws -> ConsoleLoginStatus {
        try requireV2()
        let path = try oauthPath(attemptID)
        let value = try await apiJSON(path: path)
        guard let status = value as? [String: Any], let name = status["status"] as? String else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode sign-in status")
        }
        switch name {
        case "pending": return .pending
        case "complete": return .complete
        case "failed": return .failed(status["message"] as? String ?? "OpenCode sign-in failed")
        case "expired": return .expired(status["message"] as? String ?? "OpenCode sign-in expired")
        default: throw ConsoleServiceError.invalidResponse("Unknown OpenCode sign-in status")
        }
    }

    public func loginComplete(attemptID: String, code: String) async throws {
        try requireV2()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048 else {
            throw ConsoleServiceError.invalidResponse("Enter a valid sign-in code")
        }
        let path = try oauthPath(attemptID) + "/complete"
        let body = try JSONSerialization.data(withJSONObject: ["code": trimmed])
        try await apiRequest(path: path, method: "POST", body: body, accepted: 200..<300)
    }

    public func loginCancel(attemptID: String) async throws {
        try requireV2()
        let path = try oauthPath(attemptID)
        try await apiRequest(path: path, method: "DELETE", accepted: 200..<300, additionallyAccepted: [404])
    }

    public func activate(_ credentialID: String) async throws -> OpenCodeStatus {
        _ = try await requireCredential(credentialID)
        let path = "/api/credential/\(Self.pathComponent(credentialID))/activate"
        try await apiRequest(path: path, method: "POST", accepted: 200..<300)
        guard let manager else { return .stopped }
        return await manager.activeConsoleAccountDidChange(credentialID)
    }

    /// Removes the credential through OpenCode; RelayDock never reads or stores its secret value.
    public func remove(_ credentialID: String) async throws -> String {
        let credential = try await requireCredential(credentialID)
        let path = "/api/credential/\(Self.pathComponent(credentialID))"
        try await apiRequest(path: path, method: "DELETE", accepted: 200..<300)
        let label = credential["label"] as? String ?? "OpenCode Console account"
        return "Removed \(label)"
    }

    private func requireV2() throws {
        guard let connection = connectionProvider() else { throw ConsoleServiceError.serverNotRunning }
        guard connection.majorVersion == 2 else { throw ConsoleServiceError.requiresV2 }
    }

    private func requireV1() throws {
        guard let connection = connectionProvider() else { throw ConsoleServiceError.serverNotRunning }
        guard connection.majorVersion == 1 else { throw ConsoleServiceError.requiresV1 }
    }

    private func credentialRecords() async throws -> [[String: Any]] {
        try requireV2()
        let value = try await apiJSON(path: "/api/credential")
        guard let credentials = value as? [Any] else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode credential response")
        }
        return credentials.compactMap { $0 as? [String: Any] }
    }

    private func requireCredential(_ credentialID: String) async throws -> [String: Any] {
        guard !credentialID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, credentialID.count <= 256 else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode Console credential ID")
        }
        guard let credential = try await credentialRecords().first(where: {
            $0["id"] as? String == credentialID && $0["integrationID"] as? String == Self.integrationID
        }) else {
            throw ConsoleServiceError.invalidResponse("OpenCode Console credential not found")
        }
        return credential
    }

    private func oauthPath(_ attemptID: String) throws -> String {
        guard !attemptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attemptID.count <= 256 else {
            throw ConsoleServiceError.invalidResponse("Invalid OpenCode sign-in attempt ID")
        }
        return "/api/integration/\(Self.integrationID)/connect/oauth/\(Self.pathComponent(attemptID))"
    }

    private func apiRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        accepted: Range<Int> = 200..<300,
        additionallyAccepted: Set<Int> = []
    ) async throws {
        let response = try await rawRequest(path: path, method: method, body: body)
        guard accepted.contains(response.statusCode) || additionallyAccepted.contains(response.statusCode) else {
            throw ConsoleServiceError.requestFailed("OpenCode API returned HTTP \(response.statusCode)")
        }
    }

    private func apiJSON(path: String, method: String = "GET", body: Data? = nil) async throws -> Any {
        let response = try await rawRequest(path: path, method: method, body: body)
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: response.body, encoding: .utf8) ?? ""
            let safeDetail = detail.contains("IntegrationNotFoundError") ? " IntegrationNotFoundError" : ""
            throw ConsoleServiceError.requestFailed("OpenCode API returned HTTP \(response.statusCode).\(safeDetail)")
        }
        guard !response.body.isEmpty else { return NSNull() }
        do {
            let value = try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
            if let record = value as? [String: Any], let data = record["data"] { return data }
            return value
        } catch {
            throw ConsoleServiceError.invalidResponse("Invalid JSON response from OpenCode")
        }
    }

    private func rawRequest(path: String, method: String, body: Data?) async throws -> ConsoleAPIResponse {
        guard let connection = connectionProvider() else { throw ConsoleServiceError.serverNotRunning }
        var headers = connection.headers
        headers["Accept"] = "application/json"
        if body != nil { headers["Content-Type"] = "application/json" }
        let request = ConsoleAPIRequest(port: connection.port, path: path, method: method, headers: headers, body: body)
        if let transport { return try await transport(request) }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = connection.port
        components.percentEncodedPath = path
        guard let url = components.url else { throw ConsoleServiceError.invalidResponse("Could not construct OpenCode API URL") }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        urlRequest.httpMethod = method
        urlRequest.httpBody = body
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            let (data, response) = try await session.data(for: urlRequest)
            session.invalidateAndCancel()
            guard let response = response as? HTTPURLResponse else {
                throw ConsoleServiceError.requestFailed("OpenCode returned a non-HTTP response")
            }
            return ConsoleAPIResponse(statusCode: response.statusCode, body: data)
        } catch let error as ConsoleServiceError {
            throw error
        } catch {
            throw ConsoleServiceError.requestFailed("OpenCode request failed: \(error.localizedDescription)")
        }
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
