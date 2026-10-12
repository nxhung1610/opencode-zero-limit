import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import { delimiter, join, resolve } from "node:path";
import { buildOpenCodeProxyEnv } from "./proxy.js";
import type { SettingsStore } from "./settings.js";
import type { OpencodeStatus } from "./types.js";

const sleep = (ms: number) => new Promise<void>((resolveSleep) => setTimeout(resolveSleep, ms));

async function freePort(): Promise<number> {
  const { createServer } = await import("node:net");
  const listener = createServer();
  await new Promise<void>((resolveListen, reject) => {
    listener.once("error", reject);
    listener.listen(0, "127.0.0.1", () => resolveListen());
  });
  const address = listener.address();
  if (!address || typeof address === "string") {
    listener.close();
    throw new Error("could not allocate a local port");
  }
  await new Promise<void>((resolveClose, reject) => listener.close((error) => error ? reject(error) : resolveClose()));
  return address.port;
}

export class OpencodeManager {
  private child: ChildProcess | null = null;
  private port: number | null = null;
  private error: string | null = null;
  private cliMajorVersion: number | null = null;
  private serverPassword: string | null = null;
  private startTask: Promise<OpencodeStatus> | null = null;
  private stopping = new WeakSet<ChildProcess>();

  constructor(
    private readonly settings: SettingsStore,
    private readonly selectProxy: () => string | null,
  ) {}

  getPort(): number | null {
    return this.port;
  }

  getCliMajorVersion(): number | null {
    return this.cliMajorVersion;
  }

  apiHeaders(): Record<string, string> {
    if (this.serverPassword === null) return {};
    const credentials = Buffer.from(`opencode:${this.serverPassword}`).toString("base64");
    return { Authorization: `Basic ${credentials}` };
  }

  resolveBinary(): string | null {
    return resolveBinary(this.settings.load().opencodeBin);
  }

  start(): Promise<OpencodeStatus> {
    if (this.startTask) return this.startTask;
    const task = this.startInternal();
    let tracked: Promise<OpencodeStatus>;
    tracked = task.finally(() => {
      if (this.startTask === tracked) this.startTask = null;
    });
    this.startTask = tracked;
    return tracked;
  }

  private async startInternal(): Promise<OpencodeStatus> {
    if (this.child && this.port !== null) {
      const existingPort = this.port;
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const version = await probe(existingPort, this.cliMajorVersion, this.serverPassword);
        if (version) return this.statusFromHealthy(existingPort, version);
        await sleep(250);
      }
      await this.stopChild();
    }

    const binary = this.resolveBinary();
    if (!binary) {
      this.cliMajorVersion = null;
      this.serverPassword = null;
      this.error = "opencode binary not found (install opencode or set OPENCODE_BIN)";
      return this.snapshot(false, false, null);
    }

    try {
      this.cliMajorVersion = installedCliMajorVersion(binary);
    } catch (error) {
      this.cliMajorVersion = null;
      this.serverPassword = null;
      this.error = error instanceof Error ? error.message : String(error);
      return this.snapshot(false, false, null);
    }
    if (this.cliMajorVersion !== 1 && this.cliMajorVersion !== 2) {
      const major = this.cliMajorVersion;
      this.cliMajorVersion = null;
      this.error = `unsupported OpenCode CLI major version: ${major}`;
      return this.snapshot(false, false, null);
    }
    this.serverPassword = this.cliMajorVersion === 2 ? randomBytes(32).toString("base64url") : null;

    let port: number;
    try {
      port = await freePort();
    } catch (error) {
      this.error = error instanceof Error ? error.message : String(error);
      return this.snapshot(false, false, null);
    }

    let proxy: string | null = null;
    try {
      proxy = this.selectProxy();
    } catch (error) {
      console.warn(`[proxy] could not select a proxy; starting direct: ${error instanceof Error ? error.message : String(error)}`);
    }
    const env = buildOpenCodeProxyEnv(proxy);
    delete env.OPENCODE_SERVER_PASSWORD;
    delete env.OPENCODE_SERVER_USERNAME;
    if (this.serverPassword !== null) {
      env.OPENCODE_SERVER_PASSWORD = this.serverPassword;
      env.OPENCODE_SERVER_USERNAME = "opencode";
    }
    if (proxy) console.log("[opencode] spawning with selected proxy");

    let child: ChildProcess;
    try {
      child = spawn(binary, ["serve", "--port", String(port), "--hostname", "127.0.0.1"], {
        env,
        stdio: "ignore",
        windowsHide: true,
        shell: process.platform === "win32" && /\.cmd$/i.test(binary),
      });
    } catch (error) {
      this.error = `failed to spawn opencode serve: ${error instanceof Error ? error.message : String(error)}`;
      return this.snapshot(false, false, null);
    }

    this.child = child;
    this.port = port;
    this.error = null;
    child.once("error", (error) => {
      if (this.child !== child) return;
      this.child = null;
      this.port = null;
      this.cliMajorVersion = null;
      this.serverPassword = null;
      this.error = `failed to spawn opencode serve: ${error.message}`;
    });
    child.once("exit", (code, signal) => {
      if (this.child !== child) return;
      this.child = null;
      this.port = null;
      this.cliMajorVersion = null;
      this.serverPassword = null;
      if (!this.stopping.has(child)) {
        this.error = `opencode serve exited${signal ? ` (${signal})` : ` with code ${code ?? "unknown"}`}`;
      }
    });

    for (let attempt = 0; attempt < 40; attempt += 1) {
      if (this.child !== child) break;
      const version = await probe(port, this.cliMajorVersion, this.serverPassword);
      if (version) return this.statusFromHealthy(port, version);
      await sleep(250);
    }

    this.error = "opencode serve did not become healthy in time";
    return this.snapshot(this.child === child, false, port);
  }

  async status(): Promise<OpencodeStatus> {
    if (this.port === null) return this.snapshot(false, false, null);
    const port = this.port;
    const version = await probe(port, this.cliMajorVersion, this.serverPassword);
    if (version) return this.statusFromHealthy(port, version);
    return this.snapshot(this.child !== null, false, port);
  }

  async stop(): Promise<OpencodeStatus> {
    const starting = this.startTask;
    if (starting) await starting.catch(() => undefined);
    return this.stopChild();
  }

  private async stopChild(): Promise<OpencodeStatus> {
    const child = this.child;
    if (child) {
      this.stopping.add(child);
      child.kill("SIGTERM");
      const exited = await waitForExit(child, 2_000);
      if (!exited) {
        child.kill("SIGKILL");
        await waitForExit(child, 1_000);
      }
      if (this.child === child) this.child = null;
    }
    this.port = null;
    this.cliMajorVersion = null;
    this.serverPassword = null;
    return this.snapshot(false, false, null);
  }

  async restart(): Promise<OpencodeStatus> {
    await this.stop();
    return this.start();
  }

  private statusFromHealthy(port: number, version: string): OpencodeStatus {
    this.error = null;
    return { running: true, healthy: true, port, version, error: null };
  }

  private snapshot(running: boolean, healthy: boolean, port: number | null): OpencodeStatus {
    return { running, healthy, port, version: null, error: this.error };
  }
}

function waitForExit(child: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolveExit) => {
    let settled = false;
    const finish = (exited: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeListener("close", onClose);
      resolveExit(exited);
    };
    const onClose = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMs);
    child.once("close", onClose);
  });
}

async function probe(port: number, cliMajorVersion: number | null, password: string | null): Promise<string | null> {
  try {
    const isV2 = cliMajorVersion === 2;
    const headers = isV2 && password !== null
      ? { Authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` }
      : undefined;
    const response = await fetch(`http://127.0.0.1:${port}${isV2 ? "/api/info" : "/global/health"}`, {
      headers,
      signal: AbortSignal.timeout(800),
    });
    if (!response.ok) return null;
    const body = await response.json() as { healthy?: unknown; version?: unknown };
    if (typeof body.version !== "string") return null;
    return isV2 || body.healthy === true ? body.version : null;
  } catch {
    return null;
  }
}

function installedCliMajorVersion(binary: string): number {
  let output: string;
  try {
    output = execFileSync(binary, ["--version"], {
      encoding: "utf8",
      timeout: 5_000,
      windowsHide: true,
      shell: process.platform === "win32" && /\.cmd$/i.test(binary),
    }).trim();
  } catch (error) {
    throw new Error(`could not read OpenCode CLI version: ${error instanceof Error ? error.message : String(error)}`);
  }
  const match = output.match(/\bv?(\d+)\.\d+\.\d+\b/);
  if (!match) throw new Error(`could not parse OpenCode CLI version: ${output || "empty output"}`);
  return Number(match[1]);
}

export function resolveBinary(configured?: string | null): string | null {
  const explicit = process.env.OPENCODE_BIN?.trim();
  if (explicit && existsSync(expandHome(explicit))) return resolve(expandHome(explicit));
  if (configured?.trim() && existsSync(expandHome(configured.trim()))) return resolve(expandHome(configured.trim()));

  const lookup = process.platform === "win32" ? "where.exe" : "/bin/sh";
  try {
    const output = process.platform === "win32"
      ? execFileSync(lookup, ["opencode"], { encoding: "utf8", timeout: 3_000, windowsHide: true })
      : execFileSync(lookup, ["-lc", "command -v opencode"], { encoding: "utf8", timeout: 3_000 });
    const found = output.split(/\r?\n/).map((value) => value.trim()).find(Boolean);
    if (found && existsSync(found)) return resolve(found);
  } catch {
    // Continue through PATH and common package-manager locations.
  }

  const home = process.env.HOME || process.env.USERPROFILE || "";
  const executableNames = process.platform === "win32" ? ["opencode.exe", "opencode.cmd", "opencode"] : ["opencode"];
  const candidates: string[] = [];
  for (const directory of (process.env.PATH ?? "").split(delimiter).filter(Boolean)) {
    for (const name of executableNames) candidates.push(join(directory, name));
  }
  const commonDirectories = process.platform === "darwin"
    ? ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    : process.platform === "win32"
      ? []
      : ["/usr/local/bin", "/usr/bin"];
  for (const directory of commonDirectories) {
    for (const name of executableNames) candidates.push(join(directory, name));
  }
  for (const relative of [".local/bin", ".bun/bin", ".cargo/bin", ".npm-global/bin", ".yarn/bin"]) {
    for (const name of executableNames) candidates.push(join(home, relative, name));
  }
  if (home) {
    const nvmRoot = join(home, ".nvm", "versions", "node");
    try {
      const versions = readdirSync(nvmRoot).sort().reverse();
      for (const version of versions) candidates.push(join(nvmRoot, version, "bin", "opencode"));
    } catch {
      // nvm is optional.
    }
  }
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

function expandHome(path: string): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  return path === "~" ? home : path.startsWith("~/") ? join(home, path.slice(2)) : path;
}
