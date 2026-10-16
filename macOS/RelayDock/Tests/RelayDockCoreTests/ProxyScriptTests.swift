import CryptoKit
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
        if (typeof module !== "undefined") { throw new Error("module leaked"); }
        if (typeof fetch !== "function") { throw new Error("fetch is missing"); }
        if (typeof setTimeout !== "function") { throw new Error("setTimeout is missing"); }
        if (typeof Buffer !== "object") { throw new Error("Buffer is missing"); }
        if (typeof cache !== "object") { throw new Error("cache is missing"); }
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
            _ = try ProxyScriptRunner.resolve(script: "return \"http://edge.example:8080\";", cacheID: nil, timeout: 0.15) { _, _ in
                Thread.sleep(forTimeInterval: 5)
                return .success("http://edge.example:8080")
            }
            Issue.record("A stalled script must time out")
        } catch {
            #expect(error as? ProxyScriptError == .timedOut)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    // MARK: - Node-flavoured environment

    @Test func asyncAwaitRunsThroughThePump() throws {
        let script = """
        const port = await Promise.resolve(9092);
        return "http://proxy.example:" + port;
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://proxy.example:9092")
    }

    @Test func timersBridgeAwait() throws {
        let script = """
        const port = await new Promise(function (resolve) {
          setTimeout(function () { resolve(9093); }, 10);
        });
        return "http://proxy.example:" + port;
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://proxy.example:9093")
    }

    @Test func settledScriptsIgnorePendingTimers() throws {
        let script = """
        setTimeout(function () { throw new Error("late failure"); }, 50);
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func pendingTimersWithoutResultTimeOutAndFailClosed() {
        let script = """
        await new Promise(function () { setTimeout(function () {}, 5000); });
        return "http://edge.example:8080";
        """
        do {
            _ = try ProxyScriptRunner.resolve(script, timeout: 0.3)
            Issue.record("A script that never settles must time out")
        } catch {
            #expect(error as? ProxyScriptError == .timedOut)
        }
    }

    @Test func unsettledPromisesWithoutTimersFailClosed() {
        let script = """
        await new Promise(function () {});
        return "http://edge.example:8080";
        """
        do {
            _ = try ProxyScriptRunner.resolve(script, timeout: 2)
            Issue.record("A promise with nothing pending must fail")
        } catch {
            guard case .failed(let message)? = error as? ProxyScriptError else {
                Issue.record("Expected a failed outcome, got \(error)")
                return
            }
            #expect(message.contains("did not settle"))
        }
    }

    @Test func fetchRejectsWithoutNetworkAccessAndScriptCanCatch() throws {
        let script = """
        try {
          await fetch("ftp://example.com/list");
          throw new Error("fetch must reject non-http URLs");
        } catch (error) {
          if (!String(error).includes("http.get")) { throw new Error("unexpected error: " + error); }
        }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func fetchRejectsUnsupportedMethods() throws {
        let script = """
        try {
          await fetch("https://example.com", { method: "DELETE" });
          throw new Error("fetch must reject unsupported methods");
        } catch (error) {
          if (!String(error).includes("not supported")) { throw new Error("unexpected error: " + error); }
        }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func httpPostValidatesBeforeAnyNetworkAccess() {
        do {
            _ = try ProxyScriptRunner.resolve("return http.post(\"http://example.com/rotate\", \"x\".repeat(70000));")
            Issue.record("An oversized POST body must fail")
        } catch {
            guard case .failed(let message)? = error as? ProxyScriptError else {
                Issue.record("Expected a failed outcome, got \(error)")
                return
            }
            #expect(message.contains("http.post"))
        }
    }

    @Test func cryptoHashesMatchCryptoKit() throws {
        let data = "relaydock-crypto-check"
        let expectedSHA = SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "secret-key"
        let secret = SymmetricKey(data: Data(key.utf8))
        let expectedHMAC = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: secret)
            .map { String(format: "%02x", $0) }.joined()
        let script = """
        const hash = crypto.createHash("sha256").update("\(data)").digest("hex");
        if (hash !== "\(expectedSHA)") { throw new Error("sha256 mismatch: " + hash); }
        const mac = crypto.createHmac("sha256", "\(key)").update("\(data)").digest("hex");
        if (mac !== "\(expectedHMAC)") { throw new Error("hmac mismatch: " + mac); }
        const b64 = crypto.createHash("sha256").update("\(data)").digest("base64");
        if (Buffer.from(b64, "base64").toString("hex") !== "\(expectedSHA)") {
          throw new Error("base64 digest mismatch");
        }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func cryptoRandomPrimitivesAreUsable() throws {
        let script = """
        const id = crypto.randomUUID();
        if (!/^[0-9a-f-]{36}$/.test(id)) { throw new Error("bad uuid: " + id); }
        const bytes = crypto.randomBytes(8);
        if (bytes.toString("hex").length !== 16) { throw new Error("bad randomBytes"); }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func urlAndSearchParamsBehave() throws {
        let script = """
        const u = new URL("http://user:pw@proxy.example:8080/path?a=1&b=two%20words");
        if (u.hostname !== "proxy.example") { throw new Error("hostname " + u.hostname); }
        if (u.port !== "8080") { throw new Error("port " + u.port); }
        if (u.username !== "user") { throw new Error("username " + u.username); }
        if (u.pathname !== "/path") { throw new Error("pathname " + u.pathname); }
        if (u.searchParams.get("b") !== "two words") { throw new Error("param " + u.searchParams.get("b")); }
        u.searchParams.set("c", "3");
        if (u.searchParams.toString() !== "a=1&b=two+words&c=3") {
          throw new Error("render " + u.searchParams.toString());
        }
        if (u.toString() !== "http://user:pw@proxy.example:8080/path?a=1&b=two+words&c=3") {
          throw new Error("url " + u.toString());
        }
        return "http://" + u.host;
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://proxy.example:8080")
    }

    @Test func bytesAndTextHelpersRoundTrip() throws {
        let script = """
        const encoded = new TextEncoder().encode("héllo→🚀");
        const decoded = new TextDecoder().decode(encoded);
        if (decoded !== "héllo→🚀") { throw new Error("utf8 roundtrip: " + decoded); }
        if (Buffer.from("hello world").toString("base64") !== "aGVsbG8gd29ybGQ=") { throw new Error("base64"); }
        if (Buffer.from("68656c6c6f", "hex").toString("utf8") !== "hello") { throw new Error("hex decode"); }
        if (Buffer.byteLength("héllo") !== 6) { throw new Error("byteLength " + Buffer.byteLength("héllo")); }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    @Test func structuredClonePerformanceAndQueueMicrotaskExist() throws {
        let script = """
        const copy = structuredClone({ list: [1, 2], nested: { ok: true } });
        if (copy.list[1] !== 2 || copy.nested.ok !== true) { throw new Error("clone"); }
        if (!(performance.now() >= 0)) { throw new Error("performance"); }
        let microtask = false;
        queueMicrotask(function () { microtask = true; });
        await Promise.resolve();
        if (!microtask) { throw new Error("queueMicrotask"); }
        return "http://edge.example:8080";
        """
        #expect(try ProxyScriptRunner.resolve(script) == "http://edge.example:8080")
    }

    // MARK: - Memory cache

    @Test func memoryCachePersistsPerEntryAcrossRuns() throws {
        let entryID = "test-entry-\(UUID().uuidString)"
        let script = """
        cache.runs = (cache.runs || 0) + 1;
        return "http://proxy.example:" + (9000 + cache.runs);
        """
        #expect(try ProxyScriptRunner.resolve(script, cacheID: entryID) == "http://proxy.example:9001")
        #expect(try ProxyScriptRunner.resolve(script, cacheID: entryID) == "http://proxy.example:9002")
        #expect(try ProxyScriptRunner.resolve(script, cacheID: "other-\(UUID().uuidString)") == "http://proxy.example:9001")
        #expect(try ProxyScriptRunner.resolve(script) == "http://proxy.example:9001")
    }

    @Test func memoryCacheIsDroppedWhenARunFails() {
        let entryID = "test-entry-\(UUID().uuidString)"
        let script = """
        cache.runs = (cache.runs || 0) + 1;
        throw new Error("boom-" + cache.runs);
        """
        for _ in 0..<2 {
            do {
                _ = try ProxyScriptRunner.resolve(script, cacheID: entryID)
                Issue.record("The script must fail")
            } catch {
                guard case .failed(let message)? = error as? ProxyScriptError else {
                    Issue.record("Expected a failed outcome, got \(error)")
                    return
                }
                #expect(message.contains("boom-1"))
            }
        }
    }
}
