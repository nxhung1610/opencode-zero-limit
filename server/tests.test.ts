import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { createServer, request as httpRequest, type ServerResponse } from "node:http";
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import test, { mock } from "node:test";
import { LocalWebServer, requestHeadersAllowed } from "./webServer.js";
import { OpencodeManager } from "./opencode.js";
import { buildOpenCodeProxyEnv, normalizeProxyState, parseProxyImportLine, ProxyStore } from "./proxy.js";
import { SettingsStore } from "./settings.js";
import {
  consoleActivate,
  consoleConnections,
  consoleLoginStart,
  consoleLoginStatus,
  consoleLogout,
} from "./console.js";
import { activeAccountKey, summary } from "./usage.js";
import { parseQuotaEvent, QuotaWatcher } from "./watcher.js";
import type { QuotaEvent } from "./types.js";

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), "relaydock-test-"));
}

function getStatusWithHost(base: string, host: string): Promise<number> {
  const url = new URL(base);
  return new Promise((resolveStatus, reject) => {
    const request = httpRequest({
      hostname: "127.0.0.1",
      port: Number(url.port),
      path: "/api/session",
      method: "GET",
      headers: { host },
    }, (response) => {
      response.resume();
      response.once("end", () => resolveStatus(response.statusCode ?? 0));
    });
    request.once("error", reject);
    request.end();
  });
}

test("local API host/origin checks reject DNS rebinding and cross-origin mutations", () => {
  assert.equal(requestHeadersAllowed(
    "127.0.0.1:4312", "http://127.0.0.1:4312", "127.0.0.1:4312", "http://127.0.0.1:4312", true,
  ), true);
  assert.equal(requestHeadersAllowed(
    "attacker.example:4312", "http://attacker.example:4312", "127.0.0.1:4312", "http://127.0.0.1:4312", true,
  ), false);
  assert.equal(requestHeadersAllowed(
    "127.0.0.1:4312", "https://attacker.example", "127.0.0.1:4312", "http://127.0.0.1:4312", true,
  ), false);
  assert.equal(requestHeadersAllowed(
    "127.0.0.1:4312", undefined, "127.0.0.1:4312", "http://127.0.0.1:4312", true,
  ), false);
  assert.equal(requestHeadersAllowed(
    "127.0.0.1:4312", undefined, "127.0.0.1:4312", "http://127.0.0.1:4312", false,
  ), true);
});

test("settings preserve defaults and read legacy snake_case files", () => {
  const root = tempDir();
  try {
    const file = join(root, "settings.json");
    const store = new SettingsStore(file);
    assert.deepEqual(store.load(), {
      autoRotate: false, autoStart: true, opencodeBin: null, theme: "dark",
    });
    writeFileSync(file, JSON.stringify({ auto_rotate: true, auto_start: false, opencode_bin: "/legacy/opencode", theme: "light" }));
    assert.deepEqual(store.load(), {
      autoRotate: true, autoStart: false, opencodeBin: "/legacy/opencode", theme: "light",
    });
    store.save({ auto_rotate: true, auto_start: false, opencode_bin: "/legacy/again", theme: "light" });
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), {
      autoRotate: true, autoStart: false, opencodeBin: "/legacy/again", theme: "light",
    });
    store.save({ autoRotate: false, autoStart: true, opencodeBin: null, theme: "dark" });
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), {
      autoRotate: false, autoStart: true, opencodeBin: null, theme: "dark",
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("settings keep an unreadable file aside before a save replaces it", () => {
  const root = tempDir();
  const warn = mock.method(console, "warn", () => {});
  try {
    const file = join(root, "settings.json");
    writeFileSync(file, "{broken");
    const store = new SettingsStore(file);
    assert.deepEqual(store.load(), {
      autoRotate: false, autoStart: true, opencodeBin: null, theme: "dark",
    });
    assert.equal(warn.mock.callCount(), 1);
    store.save({ autoRotate: true, autoStart: true, opencodeBin: null, theme: "light" });
    const kept = readdirSync(root).filter((name) => name.startsWith("settings.json.corrupt-"));
    assert.equal(kept.length, 1);
    assert.equal(readFileSync(join(root, kept[0] ?? ""), "utf8"), "{broken");
    assert.equal(JSON.parse(readFileSync(file, "utf8")).autoRotate, true);
  } finally {
    warn.mock.restore();
    rmSync(root, { recursive: true, force: true });
  }
});

test("default OpenCode wrapper applies RelayDock proxy settings without replacing the real CLI", () => {
  const root = tempDir();
  const fakeBin = join(root, "fake-bin");
  const configDir = join(root, "config");
  mkdirSync(fakeBin, { recursive: true });
  const fakeCli = join(fakeBin, "opencode");
  writeFileSync(fakeCli, `#!/usr/bin/env node
console.log(JSON.stringify({ args: process.argv.slice(2), httpProxy: process.env.HTTP_PROXY ?? null, httpsProxy: process.env.HTTPS_PROXY ?? null, allProxy: process.env.ALL_PROXY ?? null, noProxy: process.env.NO_PROXY ?? null }));
`);
  chmodSync(fakeCli, 0o755);
  const store = new ProxyStore(join(configDir, "proxies.json"));
  const wrapper = resolve(process.cwd(), "bin", "opencode-proxy.cjs");
  const runWrapped = () => JSON.parse(execFileSync(process.execPath, [wrapper, "--version"], {
    encoding: "utf8",
    env: {
      ...process.env,
      RELAYDOCK_CONFIG_DIR: configDir,
      PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
      HTTP_PROXY: "http://inherited.invalid:8080",
      HTTPS_PROXY: "http://inherited.invalid:8080",
      ALL_PROXY: "http://inherited.invalid:8080",
      NO_PROXY: "corp.internal",
      no_proxy: "corp.internal",
    },
  })) as { args: string[]; httpProxy: string | null; httpsProxy: string | null; allProxy: string | null; noProxy: string | null };

  try {
    store.save({
      mode: "manual",
      manualId: "test-proxy",
      proxies: [{ id: "test-proxy", label: "Test", url: "http://127.0.0.1:8765", enabled: true, health: null }],
      bindings: {},
    });
    const proxied = runWrapped();
    assert.deepEqual(proxied.args, ["--version"]);
    assert.equal(proxied.httpProxy, "http://127.0.0.1:8765");
    assert.equal(proxied.httpsProxy, "http://127.0.0.1:8765");
    assert.equal(proxied.allProxy, "http://127.0.0.1:8765");
    assert.equal(proxied.noProxy, "corp.internal,localhost,127.0.0.1");

    store.save({ mode: "off", manualId: null, proxies: [], bindings: {} });
    const direct = runWrapped();
    assert.equal(direct.httpProxy, null);
    assert.equal(direct.httpsProxy, null);
    assert.equal(direct.allProxy, null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("default OpenCode wrapper refuses to start OpenCode when the selected proxy is unusable", () => {
  const root = tempDir();
  const fakeBin = join(root, "fake-bin");
  const configDir = join(root, "config");
  const marker = join(root, "cli-ran");
  mkdirSync(fakeBin, { recursive: true });
  const fakeCli = join(fakeBin, "opencode");
  writeFileSync(fakeCli, `#!/usr/bin/env node
require("node:fs").writeFileSync(${JSON.stringify(marker)}, "ran");
`);
  chmodSync(fakeCli, 0o755);
  new ProxyStore(join(configDir, "proxies.json")).save({
    mode: "manual",
    manualId: "disabled-proxy",
    proxies: [{ id: "disabled-proxy", label: "Disabled", url: "http://127.0.0.1:8765", enabled: false, health: null }],
    bindings: {},
  });
  const wrapper = resolve(process.cwd(), "bin", "opencode-proxy.cjs");
  try {
    const result = spawnSync(process.execPath, [wrapper, "--version"], {
      encoding: "utf8",
      env: {
        ...process.env,
        RELAYDOCK_CONFIG_DIR: configDir,
        PATH: `${fakeBin}${delimiter}${process.env.PATH ?? ""}`,
      },
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /is disabled/);
    assert.equal(existsSync(marker), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("OpenCode proxy env keeps the user's NO_PROXY entries and always bypasses localhost", () => {
  const proxied = buildOpenCodeProxyEnv("http://127.0.0.1:8765", {
    NO_PROXY: "corp.internal,localhost",
    HTTPS_PROXY: "http://old.invalid:1",
  });
  assert.equal(proxied.HTTPS_PROXY, "http://127.0.0.1:8765");
  assert.equal(proxied.NO_PROXY, "corp.internal,localhost,127.0.0.1");
  assert.equal(proxied.no_proxy, "localhost,127.0.0.1");

  const direct = buildOpenCodeProxyEnv(null, { HTTPS_PROXY: "http://old.invalid:1", no_proxy: "corp.internal" });
  assert.equal(direct.HTTPS_PROXY, undefined);
  assert.equal(direct.NO_PROXY, "localhost,127.0.0.1");
  assert.equal(direct.no_proxy, "corp.internal,localhost,127.0.0.1");
});

test("proxy parsing preserves old formats and supports URL imports", () => {
  assert.equal(parseProxyImportLine("# comment"), null);
  assert.equal(parseProxyImportLine("host-without-port"), null);
  assert.equal(parseProxyImportLine("user:pass@127.0.0.1:8080"), "http://user:pass@127.0.0.1:8080");
  assert.equal(parseProxyImportLine("socks5://127.0.0.1:1080"), "socks5://127.0.0.1:1080");
  assert.equal(parseProxyImportLine("ftp://127.0.0.1:21"), null);

  const legacy = normalizeProxyState({
    mode: "manual",
    manual_id: "proxy-1",
    proxies: [{
      id: "proxy-1", label: "localhost", url: "http://localhost:8080", enabled: true,
      health: { ok: true, latency_ms: 12, checked_at: 123, error: null },
    }],
    bindings: {},
  });
  assert.equal(legacy.mode, "manual");
  assert.equal(legacy.manualId, "proxy-1");
  assert.equal(legacy.proxies[0]?.health?.latencyMs, 12);
  assert.equal(legacy.proxies[0]?.health?.checkedAt, 123);

  const root = tempDir();
  try {
    const store = new ProxyStore(join(root, "proxies.json"));
    const state = store.import("# pool\n127.0.0.1:8080\n127.0.0.1:8080\nsocks5://127.0.0.1:1080");
    assert.equal(state.proxies.length, 2);
    assert.equal(state.proxies[0]?.label, "127.0.0.1:8080");
    assert.equal(JSON.parse(readFileSync(join(root, "proxies.json"), "utf8")).mode, "off");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("proxy selection follows the mode, keeps one sticky proxy per account, and never falls back to direct", () => {
  const root = tempDir();
  const previousXdg = process.env.XDG_DATA_HOME;
  const dataDir = join(root, "opencode");
  mkdirSync(dataDir);
  const database = new DatabaseSync(join(dataDir, "opencode.db"));
  try {
    database.exec("CREATE TABLE account_state (id INTEGER PRIMARY KEY, active_account_id TEXT)");
    database.prepare("INSERT INTO account_state(id, active_account_id) VALUES (1, ?)").run("account-a");
    process.env.XDG_DATA_HOME = root;
    const store = new ProxyStore(join(root, "proxies.json"));
    const proxy = (id: string, ok: boolean | null = null, enabled = true) => ({
      id,
      label: id,
      url: `http://${id}.test:8080`,
      enabled,
      health: ok === null ? null : { ok, checkedAt: 1, latencyMs: 1, error: null },
    });
    const useAccount = (accountId: string) => {
      database.prepare("UPDATE account_state SET active_account_id = ? WHERE id = 1").run(accountId);
    };

    store.save({ mode: "manual", manualId: "px-b", proxies: [proxy("px-a", true), proxy("px-b", true)], bindings: {} });
    assert.equal(store.selectForSpawn(), "http://px-b.test:8080");
    store.save({ mode: "manual", manualId: "px-b", proxies: [proxy("px-a", true), proxy("px-b", true, false)], bindings: {} });
    assert.throws(() => store.selectForSpawn(), /is disabled/);

    store.save({
      mode: "auto",
      manualId: null,
      proxies: [proxy("px-a", false), proxy("px-b", true), proxy("px-c", true)],
      bindings: {},
    });
    assert.equal(store.selectForSpawn(), "http://px-b.test:8080");
    useAccount("account-b");
    assert.equal(store.selectForSpawn(), "http://px-c.test:8080");
    useAccount("account-a");
    assert.equal(store.selectForSpawn(), "http://px-b.test:8080");

    store.save({ mode: "auto", manualId: null, proxies: [proxy("px-a", false)], bindings: {} });
    assert.throws(() => store.selectForSpawn(), /passed its last test/);
    store.save({ mode: "auto", manualId: null, proxies: [proxy("px-a", true, false)], bindings: {} });
    assert.throws(() => store.selectForSpawn(), /at least one enabled proxy/);

    store.save({ mode: "off", manualId: null, proxies: [proxy("px-a", true)], bindings: {} });
    assert.equal(store.selectForSpawn(), null);

    store.save({ mode: "manual", manualId: "gone", proxies: [proxy("px-a", true)], bindings: {} });
    assert.equal(store.load().mode, "manual");
    assert.throws(() => store.selectForSpawn(), /No proxy is selected/);

    writeFileSync(join(root, "proxies.json"), "{broken");
    assert.throws(() => store.selectForSpawn(), /cannot read proxies\.json/);
  } finally {
    database.close();
    if (previousXdg === undefined) delete process.env.XDG_DATA_HOME;
    else process.env.XDG_DATA_HOME = previousXdg;
    rmSync(root, { recursive: true, force: true });
  }
});

test("OpenCode manager starts, probes, and stops its child process", async () => {
  const root = tempDir();
  const binary = join(root, "fake-opencode");
  const previousBinary = process.env.OPENCODE_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
if (process.argv.includes("--version")) { console.log("opencode v1.18.35"); process.exit(0); }
const http = require("node:http");
const port = Number(process.argv[process.argv.indexOf("--port") + 1]);
const server = http.createServer((request, response) => {
  if (request.url === "/global/health") {
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ healthy: true, version: "1.18.35" }));
  } else {
    response.statusCode = 404;
    response.end();
  }
});
server.listen(port, "127.0.0.1");
`);
  chmodSync(binary, 0o755);
  process.env.OPENCODE_BIN = binary;
  const manager = new OpencodeManager(new SettingsStore(join(root, "settings.json")), () => null);
  try {
    const started = await manager.start();
    assert.equal(started.running, true);
    assert.equal(started.healthy, true);
    assert.equal(started.version, "1.18.35");
    assert.ok(started.port);
    const status = await manager.status();
    assert.equal(status.healthy, true);
    const stopped = await manager.stop();
    assert.equal(stopped.running, false);
    assert.equal(stopped.port, null);
  } finally {
    await manager.stop();
    if (previousBinary === undefined) delete process.env.OPENCODE_BIN;
    else process.env.OPENCODE_BIN = previousBinary;
    rmSync(root, { recursive: true, force: true });
  }
});

test("OpenCode manager reports why serve exited during startup", async () => {
  const root = tempDir();
  const binary = join(root, "fake-opencode-crash");
  const previousBinary = process.env.OPENCODE_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
if (process.argv.includes("--version")) { console.log("opencode v1.18.35"); process.exit(0); }
console.error("fatal: provider config is invalid");
process.exitCode = 3;
`);
  chmodSync(binary, 0o755);
  process.env.OPENCODE_BIN = binary;
  const manager = new OpencodeManager(new SettingsStore(join(root, "settings.json")), () => null);
  try {
    const status = await manager.start();
    assert.equal(status.running, false);
    assert.match(status.error ?? "", /exited with code 3/);
    assert.match(status.error ?? "", /fatal: provider config is invalid/);
  } finally {
    await manager.stop();
    if (previousBinary === undefined) delete process.env.OPENCODE_BIN;
    else process.env.OPENCODE_BIN = previousBinary;
    rmSync(root, { recursive: true, force: true });
  }
});

test("OpenCode manager does not spawn serve when proxy selection fails", async () => {
  const root = tempDir();
  const binary = join(root, "fake-opencode");
  const marker = join(root, "serve-ran");
  const previousBinary = process.env.OPENCODE_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
if (process.argv.includes("--version")) { console.log("opencode v1.18.35"); process.exit(0); }
require("node:fs").writeFileSync(${JSON.stringify(marker)}, "ran");
`);
  chmodSync(binary, 0o755);
  process.env.OPENCODE_BIN = binary;
  const manager = new OpencodeManager(new SettingsStore(join(root, "settings.json")), () => {
    throw new Error("The selected proxy is disabled.");
  });
  try {
    const status = await manager.start();
    assert.equal(status.running, false);
    assert.equal(status.error, "The selected proxy is disabled.");
    assert.equal(existsSync(marker), false);
  } finally {
    await manager.stop();
    if (previousBinary === undefined) delete process.env.OPENCODE_BIN;
    else process.env.OPENCODE_BIN = previousBinary;
    rmSync(root, { recursive: true, force: true });
  }
});

test("OpenCode v2 manager and web OAuth manage only safe local Console connection metadata", async () => {
  const root = tempDir();
  const binary = join(root, "fake-opencode-v2");
  const oauthURLPath = join(root, "oauth-url.txt");
  writeFileSync(oauthURLPath, "javascript:alert(1)");
  const previousBinary = process.env.OPENCODE_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
if (process.argv.includes("--version")) { console.log("opencode v2.0.26"); process.exit(0); }
const http = require("node:http");
const port = Number(process.argv[process.argv.indexOf("--port") + 1]);
const expected = "Basic " + Buffer.from("opencode:" + process.env.OPENCODE_SERVER_PASSWORD).toString("base64");
let activeID = "cred-a";
let completed = false;
let integrationLookups = 0;
let credentials = [
  { id: "cred-a", integrationID: "opencode", label: "alpha@example.test", active: true, value: "secret-alpha" },
  { id: "cred-b", integrationID: "opencode", label: "beta@example.test", active: false, value: "secret-beta" },
  { id: "cred-other", integrationID: "anthropic", label: "other", active: true, value: "secret-other" },
];
const send = (response, status, body) => {
  response.statusCode = status;
  if (body === undefined) { response.end(); return; }
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify(body));
};
const server = http.createServer((request, response) => {
  if (request.headers.authorization !== expected) { send(response, 401, { error: "unauthorized" }); return; }
  const url = new URL(request.url || "/", "http://127.0.0.1");
  if (request.method === "GET" && url.pathname === "/api/info") { send(response, 200, { version: "2.0.26" }); return; }
  if (request.method === "GET" && url.pathname === "/api/integration/opencode") {
    integrationLookups += 1;
    if (integrationLookups === 1) {
      send(response, 404, { _tag: "IntegrationNotFoundError", integrationID: "opencode", message: "Integration not found: opencode" }); return;
    }
    send(response, 200, { data: { id: "opencode", methods: [{ id: "device", type: "oauth", label: "OpenCode Console account" }], connections: [] } }); return;
  }
  if (request.method === "GET" && url.pathname === "/api/credential") {
    send(response, 200, { data: credentials.map((item) => ({ ...item, active: item.id === activeID })) }); return;
  }
  if (request.method === "POST" && url.pathname === "/api/integration/opencode/connect/oauth") {
    send(response, 200, { data: { attemptID: "attempt-1", url: require("node:fs").readFileSync(${JSON.stringify(oauthURLPath)}, "utf8"), instructions: "Approve in browser", mode: "auto" } }); return;
  }
  if (url.pathname === "/api/integration/opencode/connect/oauth/attempt-1" && request.method === "GET") {
    send(response, 200, { data: { status: completed ? "complete" : "pending" } }); return;
  }
  if (url.pathname === "/api/integration/opencode/connect/oauth/attempt-1/complete" && request.method === "POST") {
    completed = true; send(response, 204); return;
  }
  if (url.pathname === "/api/integration/opencode/connect/oauth/attempt-1" && request.method === "DELETE") {
    send(response, 204); return;
  }
  const credentialPath = url.pathname.match(/^\\/api\\/credential\\/([^/]+)(?:\\/(activate))?$/);
  if (credentialPath && request.method === "POST" && credentialPath[2] === "activate") {
    activeID = decodeURIComponent(credentialPath[1]); send(response, 204); return;
  }
  if (credentialPath && request.method === "DELETE" && !credentialPath[2]) {
    const id = decodeURIComponent(credentialPath[1]);
    credentials = credentials.filter((item) => item.id !== id);
    if (activeID === id) activeID = credentials.find((item) => item.integrationID === "opencode")?.id || "";
    send(response, 204); return;
  }
  send(response, 404, { error: "not found" });
});
server.listen(port, "127.0.0.1");
`);
  chmodSync(binary, 0o755);
  process.env.OPENCODE_BIN = binary;
  const manager = new OpencodeManager(new SettingsStore(join(root, "settings.json")), () => null);
  try {
    const started = await manager.start();
    assert.equal(started.healthy, true);
    assert.equal(started.version, "2.0.26");
    assert.equal(manager.getCliMajorVersion(), 2);
    assert.match(manager.apiHeaders().Authorization ?? "", /^Basic /);

    const connections = await consoleConnections(manager);
    assert.deepEqual(connections, [
      { id: "cred-a", label: "alpha@example.test", active: true, method: "oauth" },
      { id: "cred-b", label: "beta@example.test", active: false, method: "oauth" },
    ]);
    assert.doesNotMatch(JSON.stringify(connections), /secret-(alpha|beta|other)/);

    await assert.rejects(consoleLoginStart(manager), /insecure browser sign-in link/);
    writeFileSync(oauthURLPath, "https://opencode.ai/console/device?code=public-code");
    const attempt = await consoleLoginStart(manager);
    assert.equal(attempt.attemptID, "attempt-1");
    assert.equal(attempt.mode, "auto");
    assert.match(attempt.url, /^https:\/\//);
    assert.deepEqual(await consoleLoginStatus(manager, attempt.attemptID), { status: "pending" });
    const distDir = join(root, "web-dist");
    mkdirSync(distDir);
    writeFileSync(join(distDir, "index.html"), "<!doctype html><title>test</title>");
    const webSettings = new SettingsStore(join(root, "web-settings.json"));
    const web = new LocalWebServer({
      version: "test",
      distDir,
      manager,
      settings: webSettings,
      proxies: new ProxyStore(join(root, "web-proxies.json")),
      watcher: new QuotaWatcher(manager, webSettings),
    });
    const base = await web.start();
    try {
      const origin = new URL(base).origin;
      const session = await fetch(new URL("api/session", base)).then((response) => response.json()) as { token: string };
      const invoke = (command: string, args: Record<string, unknown>) => fetch(new URL("api/command", base), {
        method: "POST",
        headers: { Origin: origin, "Content-Type": "application/json", "X-RelayDock-Token": session.token },
        body: JSON.stringify({ command, args }),
      });
      const completeResponse = await invoke("console_login_complete", { attemptID: attempt.attemptID, code: "user-code" });
      assert.equal(completeResponse.status, 200);
      assert.equal(await completeResponse.json(), null);
      assert.deepEqual(await consoleLoginStatus(manager, attempt.attemptID), { status: "complete" });
      const cancelResponse = await invoke("console_login_cancel", { attemptID: attempt.attemptID });
      assert.equal(cancelResponse.status, 200);
      assert.equal(await cancelResponse.json(), null);
    } finally {
      await web.stop();
    }

    await consoleActivate(manager, "cred-b");
    assert.equal((await consoleConnections(manager)).find((connection) => connection.active)?.id, "cred-b");
    await assert.rejects(consoleActivate(manager, "cred-other"), /OpenCode Console credential not found/);
    assert.equal(await consoleLogout(manager, "cred-b"), "Removed beta@example.test");
    assert.deepEqual((await consoleConnections(manager)).map((connection) => connection.id), ["cred-a"]);
  } finally {
    await manager.stop();
    if (previousBinary === undefined) delete process.env.OPENCODE_BIN;
    else process.env.OPENCODE_BIN = previousBinary;
    rmSync(root, { recursive: true, force: true });
  }
});

test("built-in SQLite reader summarizes local OpenCode usage and active account", () => {
  const root = tempDir();
  const previousXdg = process.env.XDG_DATA_HOME;
  const dataDir = join(root, "opencode");
  mkdirSync(dataDir);
  const databasePath = join(dataDir, "opencode.db");
  const database = new DatabaseSync(databasePath);
  try {
    database.exec("CREATE TABLE message (time_created INTEGER, data TEXT, session_id TEXT)");
    database.exec("CREATE TABLE account_state (id INTEGER PRIMARY KEY, active_account_id TEXT)");
    database.prepare("INSERT INTO account_state(id, active_account_id) VALUES (1, ?)").run("account-test");
    const insert = database.prepare("INSERT INTO message(time_created, data, session_id) VALUES (?, ?, ?)");
    const now = Date.now();
    insert.run(now, JSON.stringify({
      role: "assistant", modelID: "model-a", tokens: { input: 12, output: 7, reasoning: 2, cache: { read: 3, write: 1 } }, cost: 0.25,
    }), "session-a");
    insert.run(now, JSON.stringify({ role: "user" }), "session-a");
    process.env.XDG_DATA_HOME = root;
    const result = summary(7);
    assert.equal(result.assistantMessages, 1);
    assert.equal(result.userMessages, 1);
    assert.equal(result.sessions, 1);
    assert.equal(result.inputTokens, 12);
    assert.equal(result.outputTokens, 7);
    assert.equal(result.reasoningTokens, 2);
    assert.equal(result.cacheReadTokens, 3);
    assert.equal(result.cacheWriteTokens, 1);
    assert.equal(result.cost, 0.25);
    assert.deepEqual(result.models, [{ model: "model-a", requests: 1 }]);
    assert.equal(activeAccountKey(), "account-test");
  } finally {
    database.close();
    if (previousXdg === undefined) delete process.env.XDG_DATA_HOME;
    else process.env.XDG_DATA_HOME = previousXdg;
    rmSync(root, { recursive: true, force: true });
  }
});

test("quota watcher only forwards retry quota events", () => {
  const event = parseQuotaEvent({
    type: "session.status",
    properties: {
      sessionID: "session-1",
      status: {
        type: "retry", attempt: 2, next: 3,
        action: { reason: "free_tier_limit", provider: "opencode", title: "Limit", message: "Wait" },
      },
    },
  });
  assert.equal(event?.reason, "free_tier_limit");
  assert.equal(event?.sessionId, "session-1");
  assert.equal(event?.attempt, 2);
  assert.ok(event?.resetAt && event.resetAt > Date.now());
  assert.equal(parseQuotaEvent({ type: "session.status", properties: { status: { type: "retry", action: { reason: "other" } } } }), null);
  assert.equal(parseQuotaEvent({ type: "message.updated" }), null);
});

test("quota watcher uses the v2 SSE route and forwards quota events", async () => {
  const root = tempDir();
  let requestedPath = "";
  const server = createServer((request, response) => {
    requestedPath = request.url ?? "";
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.write(`data: ${JSON.stringify({
      type: "session.status",
      properties: {
        sessionID: "stream-session",
        status: { type: "retry", action: { reason: "free_tier_limit", provider: "opencode", title: "Limit", message: "Wait" } },
      },
    })}\n\n`);
  });
  const port = await new Promise<number>((resolvePort, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") reject(new Error("missing test server address"));
      else resolvePort(address.port);
    });
  });
  const settings = new SettingsStore(join(root, "settings.json"));
  const manager = {
    getPort: () => port,
    getCliMajorVersion: () => 2,
    apiHeaders: () => ({}),
  } as unknown as OpencodeManager;
  const watcher = new QuotaWatcher(manager, settings);
  try {
    const event = await new Promise<QuotaEvent>((resolveEvent, reject) => {
      const timeout = setTimeout(() => reject(new Error("quota event timed out")), 5_000);
      watcher.subscribe((next) => {
        clearTimeout(timeout);
        resolveEvent(next);
      });
      watcher.start();
    });
    assert.equal(requestedPath, "/api/event");
    assert.equal(event.sessionId, "stream-session");
    assert.equal(event.reason, "free_tier_limit");
  } finally {
    await watcher.stop();
    await new Promise<void>((resolveClose) => server.close(() => resolveClose()));
    rmSync(root, { recursive: true, force: true });
  }
});

const quotaPayload = {
  type: "session.status",
  properties: {
    sessionID: "session-quota",
    status: {
      type: "retry",
      attempt: 1,
      next: 1_000,
      action: { reason: "free_tier_limit", provider: "opencode", title: "Limit reached", message: "Wait" },
    },
  },
};

async function waitFor(condition: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("timed out waiting for condition");
    await new Promise((resolveWait) => setTimeout(resolveWait, 10));
  }
}

// Fake OpenCode HTTP server: quota event stream plus the Console routes the watcher calls. The manager is a stub.
async function startQuotaFixture(cliMajorVersion: 1 | 2) {
  const credentials: Array<{ id: string; integrationID: string; label: string; active: boolean }> = [];
  const orgs: Array<{ accountID: string; accountEmail: string; accountUrl: string; orgID: string; orgName: string; active: boolean }> = [];
  const activations: string[] = [];
  const switches: Array<{ accountID: string; orgID: string }> = [];
  let stream: ServerResponse | null = null;
  let finishedAt = 0;
  let restarts = 0;
  const send = (response: ServerResponse, status: number, body?: unknown) => {
    response.statusCode = status;
    if (body === undefined) {
      response.end();
      return;
    }
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify(body));
  };
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    if (request.method === "GET" && (url.pathname === "/api/event" || url.pathname === "/event")) {
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(": connected\n\n");
      stream = response;
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/credential") {
      send(response, 200, { data: credentials });
      return;
    }
    const activate = url.pathname.match(/^\/api\/credential\/([^/]+)\/activate$/);
    if (request.method === "POST" && activate) {
      const id = decodeURIComponent(activate[1] ?? "");
      setTimeout(() => {
        for (const credential of credentials) credential.active = credential.id === id;
        activations.push(id);
        finishedAt = Date.now();
        send(response, 204);
      }, 200);
      return;
    }
    if (request.method === "GET" && url.pathname === "/experimental/console/orgs") {
      send(response, 200, { orgs });
      return;
    }
    if (request.method === "POST" && url.pathname === "/experimental/console/switch") {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as { accountID: string; orgID: string };
        switches.push(body);
        for (const org of orgs) org.active = org.accountID === body.accountID && org.orgID === body.orgID;
        finishedAt = Date.now();
        send(response, 204);
      });
      return;
    }
    send(response, 404, { error: "not found" });
  });
  const port = await new Promise<number>((resolvePort, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") reject(new Error("missing test server address"));
      else resolvePort(address.port);
    });
  });
  const manager = {
    getPort: () => port,
    getCliMajorVersion: () => cliMajorVersion,
    apiHeaders: () => ({}),
    status: async () => ({ running: true, healthy: true, port, version: null, error: null }),
    restart: async () => {
      restarts += 1;
      return { running: true, healthy: true, port, version: null, error: null };
    },
  } as unknown as OpencodeManager;
  return {
    manager,
    credentials,
    orgs,
    activations,
    switches,
    restarts: () => restarts,
    finishedAt: () => finishedAt,
    connected: () => stream !== null,
    emitQuota: () => {
      stream?.write(`data: ${JSON.stringify(quotaPayload)}\n\n`);
    },
    close: async () => {
      stream?.end();
      await new Promise<void>((resolveClose) => {
        server.close(() => resolveClose());
        server.closeAllConnections();
      });
    },
  };
}

test("quota watcher shows a limit at once, then again once the next Console account is active", async () => {
  const root = tempDir();
  const fixture = await startQuotaFixture(2);
  fixture.credentials.push(
    { id: "cred-a", integrationID: "opencode", label: "alpha", active: true },
    { id: "cred-b", integrationID: "opencode", label: "beta", active: false },
  );
  const settings = new SettingsStore(join(root, "settings.json"));
  settings.save({ autoRotate: true, autoStart: false, opencodeBin: null, theme: "dark" });
  const received: Array<{ at: number; event: QuotaEvent }> = [];
  const watcher = new QuotaWatcher(fixture.manager, settings);
  watcher.subscribe((event) => received.push({ at: Date.now(), event }));
  try {
    watcher.start();
    await waitFor(() => fixture.connected());
    fixture.emitQuota();
    await waitFor(() => received.length === 2);
    assert.equal(received[0]?.event.rotatedTo, null);
    assert.equal(received[1]?.event.rotatedTo, "beta");
    assert.ok((received[0]?.at ?? Infinity) < fixture.finishedAt(), "the limit is shown before the switch completes");
    assert.deepEqual(fixture.activations, ["cred-b"]);

    fixture.emitQuota();
    await waitFor(() => received.length === 3);
    assert.equal(received[2]?.event.rotatedTo, null);
    assert.deepEqual(fixture.activations, ["cred-b"]);
  } finally {
    await watcher.stop();
    await fixture.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("quota watcher does not spend the rotation cooldown when there is nothing to switch to", async () => {
  const root = tempDir();
  const fixture = await startQuotaFixture(2);
  fixture.credentials.push({ id: "cred-a", integrationID: "opencode", label: "alpha", active: true });
  const settings = new SettingsStore(join(root, "settings.json"));
  settings.save({ autoRotate: true, autoStart: false, opencodeBin: null, theme: "dark" });
  const received: QuotaEvent[] = [];
  const watcher = new QuotaWatcher(fixture.manager, settings);
  watcher.subscribe((event) => received.push(event));
  try {
    watcher.start();
    await waitFor(() => fixture.connected());
    fixture.emitQuota();
    await waitFor(() => received.length === 1);
    assert.deepEqual(fixture.activations, []);

    fixture.credentials.push({ id: "cred-b", integrationID: "opencode", label: "beta", active: false });
    fixture.emitQuota();
    await waitFor(() => received.length === 3);
    assert.equal(received[2]?.rotatedTo, "beta");
    assert.deepEqual(fixture.activations, ["cred-b"]);
  } finally {
    await watcher.stop();
    await fixture.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("quota watcher switches OpenCode v1 organizations and restarts the managed server", async () => {
  const root = tempDir();
  const fixture = await startQuotaFixture(1);
  fixture.orgs.push(
    { accountID: "acc-1", accountEmail: "a@example.test", accountUrl: "", orgID: "org-1", orgName: "Personal", active: true },
    { accountID: "acc-2", accountEmail: "b@example.test", accountUrl: "", orgID: "org-2", orgName: "Team", active: false },
  );
  const settings = new SettingsStore(join(root, "settings.json"));
  settings.save({ autoRotate: true, autoStart: false, opencodeBin: null, theme: "dark" });
  const received: QuotaEvent[] = [];
  const watcher = new QuotaWatcher(fixture.manager, settings);
  watcher.subscribe((event) => received.push(event));
  try {
    watcher.start();
    await waitFor(() => fixture.connected());
    fixture.emitQuota();
    await waitFor(() => received.length === 2);
    assert.equal(received[1]?.rotatedTo, "Team · b@example.test");
    assert.deepEqual(fixture.switches, [{ accountID: "acc-2", orgID: "org-2" }]);
    assert.equal(fixture.restarts(), 1);
  } finally {
    await watcher.stop();
    await fixture.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("Node local web host serves UI and protects API mutations", async () => {
  const root = tempDir();
  const dist = join(root, "dist");
  mkdirSync(dist);
  writeFileSync(join(dist, "index.html"), "<!doctype html><title>RelayDock test</title>");
  const settings = new SettingsStore(join(root, "settings.json"));
  const proxies = new ProxyStore(join(root, "proxies.json"));
  const manager = new OpencodeManager(settings, () => null);
  const watcher = new QuotaWatcher(manager, settings);
  const web = new LocalWebServer({ version: "test", distDir: dist, manager, settings, proxies, watcher });

  try {
    const base = await web.start();
    const origin = new URL(base).origin;
    const page = await fetch(base);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /RelayDock test/);

    const sessionResponse = await fetch(new URL("api/session", base), { headers: { Origin: origin } });
    assert.equal(sessionResponse.status, 200);
    const session = await sessionResponse.json() as { token: string };
    assert.ok(session.token.length >= 32);

    assert.equal(await getStatusWithHost(base, "attacker.example"), 403);

    const badOrigin = await fetch(new URL("api/command", base), {
      method: "POST",
      headers: { Origin: "https://attacker.example", "Content-Type": "application/json", "X-RelayDock-Token": session.token },
      body: JSON.stringify({ command: "settings_get", args: {} }),
    });
    assert.equal(badOrigin.status, 403);

    const allowed = await fetch(new URL("api/command", base), {
      method: "POST",
      headers: { Origin: origin, "Content-Type": "application/json", "X-RelayDock-Token": session.token },
      body: JSON.stringify({ command: "settings_get", args: {} }),
    });
    assert.equal(allowed.status, 200);
    assert.deepEqual(await allowed.json(), {
      autoRotate: false, autoStart: true, opencodeBin: null, theme: "dark",
    });
  } finally {
    await web.stop();
    rmSync(root, { recursive: true, force: true });
  }
});
