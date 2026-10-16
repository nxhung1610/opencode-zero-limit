import Foundation
import Testing
@testable import RelayDockCore

struct ProxyScriptTests {
    @Test func resolvesALiteralReturnValue() throws {
        let url = try ProxyScriptRunner.resolve("return \"socks5://127.0.0.1:1080\";")
        #expect(url == "socks5://127.0.0.1:1080")
    }

    @Test func normalizesBareHostAndPort() throws {
        let url = try ProxyScriptRunner.resolve("return \"1.2.3.4:8080\";")
        #expect(url == "http://1.2.3.4:8080")
    }

    @Test func supportsJsonAndStringBuilding() throws {
        let script = """
        const payload = JSON.parse('{"proxy":"https://edge.example:8443"}');
        return payload.proxy;
        """
        #expect(try ProxyScriptRunner.resolve(script) == "https://edge.example:8443")
    }

    @Test func btoaAndAtobAreAvailable() throws {
        let script = """
        if (btoa("abc") !== "YWJj") { throw new Error("btoa mismatch"); }
        if (atob("YWJj") !== "abc") { throw new Error("atob mismatch"); }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func sandboxExposesNoFileOrProcessAccess() throws {
        let script = """
        if (typeof require !== "undefined") { throw new Error("require leaked"); }
        if (typeof process !== "undefined") { throw new Error("process leaked"); }
        if (typeof fetch !== "undefined") { throw new Error("fetch leaked"); }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func runtimeErrorsSurfaceTheScriptMessage() {
        do {
            _ = try ProxyScriptRunner.resolve("throw new Error(\"boom\");")
            Issue.record("A throwing script must fail")
        } catch {
            guard case .failed(let message)? = error as? ProxyScriptError else {
                Issue.record("Expected a failed outcome, got \(error)")
                return
            }
            #expect(message.contains("boom"))
        }
    }

    @Test func syntaxErrorsFailClosed() {
        do {
            _ = try ProxyScriptRunner.resolve("return (((")
            Issue.record("A syntax error must fail")
        } catch {
            guard case .failed? = error as? ProxyScriptError else {
                Issue.record("Expected a failed outcome, got \(error)")
                return
            }
        }
    }

    @Test func missingReturnValueFailsClosed() {
        do {
            _ = try ProxyScriptRunner.resolve("const value = 1;")
            Issue.record("A script without a return value must fail")
        } catch {
            #expect(error as? ProxyScriptError == .invalidResult("no value"))
        }
    }

    @Test func nonProxyReturnValuesFailClosed() {
        do {
            _ = try ProxyScriptRunner.resolve("return \"hello world\";")
            Issue.record("A non-proxy return value must fail")
        } catch {
            #expect(error as? ProxyScriptError == .invalidResult("\"hello world\""))
        }
    }

    @Test func emptyAndOversizedScriptsFailClosed() {
        #expect(throws: ProxyScriptError.empty) {
            try ProxyScriptRunner.resolve("   ")
        }
        let oversized = "// " + String(repeating: "x", count: 65_536)
        do {
            _ = try ProxyScriptRunner.resolve(oversized)
            Issue.record("An oversized script must fail")
        } catch {
            #expect(error as? ProxyScriptError == .tooLarge)
        }
    }

    @Test func httpGetRejectsNonHttpSchemesWithoutNetworkAccess() {
        do {
            _ = try ProxyScriptRunner.resolve("return http.get(\"ftp://example.com/file\");")
            Issue.record("http.get must reject non-http schemes")
        } catch {
            guard case .failed(let message)? = error as? ProxyScriptError else {
                Issue.record("Expected a failed outcome, got \(error)")
                return
            }
            #expect(message.contains("http.get"))
        }
    }

    @Test func stalledScriptsTimeOutAndFailClosed() {
        let start = Date()
        do {
            _ = try ProxyScriptRunner.resolve(script: "return \"http://edge.example:8080\";", timeout: 0.15) { _ in
                Thread.sleep(forTimeInterval: 5)
                return .success("http://edge.example:8080")
            }
            Issue.record("A stalled script must time out")
        } catch {
            #expect(error as? ProxyScriptError == .timedOut)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
