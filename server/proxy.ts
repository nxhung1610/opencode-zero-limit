import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { get as httpsGet } from "node:https";
import { join } from "node:path";
import { HttpsProxyAgent } from "https-proxy-agent";
import { SocksProxyAgent } from "socks-proxy-agent";
import { appConfigDir, writeJsonFile } from "./config.js";
import { activeAccountKey } from "./usage.js";
import type { ProxyEntry, ProxyHealth, ProxyMode, ProxyState } from "./types.js";

export const DEFAULT_PROXY_STATE: ProxyState = {
  mode: "off",
  manualId: null,
  proxies: [],
  bindings: {},
};

export function buildOpenCodeProxyEnv(proxyUrl: string | null, baseEnv: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...baseEnv,
    NO_PROXY: "localhost,127.0.0.1",
    no_proxy: "localhost,127.0.0.1",
  };
  if (proxyUrl) {
    env.HTTP_PROXY = proxyUrl;
    env.https_proxy = proxyUrl;
    env.HTTPS_PROXY = proxyUrl;
    env.http_proxy = proxyUrl;
    env.ALL_PROXY = proxyUrl;
    env.all_proxy = proxyUrl;
  } else {
    delete env.HTTP_PROXY;
    delete env.http_proxy;
    delete env.HTTPS_PROXY;
    delete env.https_proxy;
    delete env.ALL_PROXY;
    delete env.all_proxy;
  }
  return env;
}

function normalizeHealth(value: unknown): ProxyHealth | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  return {
    ok: raw.ok === true,
    latencyMs: typeof (raw.latencyMs ?? raw.latency_ms) === "number"
      ? Number(raw.latencyMs ?? raw.latency_ms)
      : null,
    checkedAt: Number(raw.checkedAt ?? raw.checked_at) || 0,
    error: typeof raw.error === "string" ? raw.error : null,
  };
}

export function normalizeProxyState(value: unknown): ProxyState {
  if (!value || typeof value !== "object" || Array.isArray(value)) return structuredClone(DEFAULT_PROXY_STATE);
  const raw = value as Record<string, unknown>;
  const mode = raw.mode === "manual" || raw.mode === "auto" ? raw.mode : "off";
  const manualId = raw.manualId ?? raw.manual_id;
  const proxies = Array.isArray(raw.proxies) ? raw.proxies : [];
  const bindingsValue = raw.bindings;
  const bindings: Record<string, string> = {};
  if (bindingsValue && typeof bindingsValue === "object" && !Array.isArray(bindingsValue)) {
    for (const [accountId, proxyId] of Object.entries(bindingsValue)) {
      if (typeof proxyId === "string") bindings[accountId] = proxyId;
    }
  }

  const entries: ProxyEntry[] = [];
  for (const value of proxies) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const entry = value as Record<string, unknown>;
    if (typeof entry.id !== "string" || typeof entry.url !== "string") continue;
    entries.push({
      id: entry.id,
      label: typeof entry.label === "string" ? entry.label : labelFor(entry.url),
      url: entry.url,
      enabled: entry.enabled !== false,
      health: normalizeHealth(entry.health),
    });
  }

  const selectedId = typeof manualId === "string" && entries.some((entry) => entry.id === manualId)
    ? manualId
    : null;
  return {
    mode: mode === "manual" && !selectedId ? "off" : mode,
    manualId: selectedId,
    proxies: entries,
    bindings,
  };
}

export function proxyEntryId(url: string): string {
  return `px_${createHash("sha256").update(url).digest("hex").slice(0, 16)}`;
}

export function labelFor(url: string): string {
  const withoutScheme = url.split("://").at(1) ?? url;
  return withoutScheme.split("@").at(-1) ?? withoutScheme;
}

function hasExplicitPort(authority: string): boolean {
  const hostPort = authority.split("@").at(-1) ?? authority;
  return hostPort.startsWith("[") ? /\]:\d+$/.test(hostPort) : /:\d+$/.test(hostPort);
}

export function parseProxyImportLine(value: string): string | null {
  const line = value.trim();
  if (!line || line.startsWith("#")) return null;
  const candidate = line.includes("://")
    ? line
    : line.includes("@") || line.includes(":")
      ? `http://${line}`
      : null;
  if (!candidate) return null;
  const schemeEnd = candidate.indexOf("://");
  const authority = candidate.slice(schemeEnd + 3).split(/[/?#]/, 1)[0] ?? "";
  if (!hasExplicitPort(authority)) return null;
  try {
    const url = new URL(candidate);
    if (!url.hostname || !["http:", "https:", "socks5:", "socks5h:"].includes(url.protocol)) return null;
    return candidate;
  } catch {
    return null;
  }
}

function health(ok: boolean, checkedAt: number, latencyMs: number | null, error: string | null): ProxyHealth {
  return { ok, checkedAt, latencyMs, error };
}

export async function checkProxy(url: string): Promise<ProxyHealth> {
  const started = Date.now();
  const checkedAt = started;
  let agent: HttpsProxyAgent<string> | SocksProxyAgent;
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "socks5:" || parsed.protocol === "socks5h:") {
      agent = new SocksProxyAgent(url);
    } else if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      agent = new HttpsProxyAgent(url);
    } else {
      return health(false, checkedAt, null, `unsupported proxy protocol: ${parsed.protocol}`);
    }
  } catch (error) {
    return health(false, checkedAt, null, error instanceof Error ? error.message : String(error));
  }

  return new Promise<ProxyHealth>((resolve) => {
    let settled = false;
    const finish = (result: ProxyHealth) => {
      if (settled) return;
      settled = true;
      agent.destroy();
      resolve(result);
    };
    const request = httpsGet(
      "https://www.gstatic.com/generate_204",
      { agent, timeout: 8_000 },
      (response) => {
        response.resume();
        response.once("end", () => {
          const status = response.statusCode ?? 0;
          finish(status >= 200 && status < 300
            ? health(true, checkedAt, Date.now() - started, null)
            : health(false, checkedAt, null, `HTTP ${status}`));
        });
      },
    );
    request.once("timeout", () => request.destroy(new Error("request timed out")));
    request.once("error", (error) => finish(health(false, checkedAt, null, error.message)));
  });
}

export class ProxyStore {
  readonly filePath: string;

  constructor(filePath = join(appConfigDir(), "proxies.json")) {
    this.filePath = filePath;
  }

  load(): ProxyState {
    if (!existsSync(this.filePath)) return structuredClone(DEFAULT_PROXY_STATE);
    try {
      return normalizeProxyState(JSON.parse(readFileSync(this.filePath, "utf8")) as unknown);
    } catch (error) {
      throw new Error(`cannot read proxies.json: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  save(state: ProxyState): ProxyState {
    writeJsonFile(this.filePath, state);
    return state;
  }

  import(text: string): ProxyState {
    const state = this.load();
    for (const line of text.split(/\r?\n/)) {
      const url = parseProxyImportLine(line);
      if (!url || state.proxies.some((entry) => entry.url === url || entry.id === proxyEntryId(url))) continue;
      state.proxies.push({
        id: proxyEntryId(url),
        label: labelFor(url),
        url,
        enabled: true,
        health: null,
      });
    }
    return this.save(state);
  }

  remove(id: string): ProxyState {
    const state = this.load();
    state.proxies = state.proxies.filter((entry) => entry.id !== id);
    if (state.manualId === id) state.manualId = null;
    for (const [accountId, proxyId] of Object.entries(state.bindings)) {
      if (proxyId === id) delete state.bindings[accountId];
    }
    return this.save(state);
  }

  setEnabled(id: string, enabled: boolean): ProxyState {
    const state = this.load();
    const entry = state.proxies.find((candidate) => candidate.id === id);
    if (entry) entry.enabled = enabled;
    return this.save(state);
  }

  setMode(mode: ProxyMode, manualId: string | null): ProxyState {
    const state = this.load();
    state.mode = mode;
    state.manualId = manualId && state.proxies.some((entry) => entry.id === manualId) ? manualId : null;
    if (state.mode === "manual" && !state.manualId) state.mode = "off";
    return this.save(state);
  }

  async checkAll(): Promise<ProxyState> {
    const state = this.load();
    const results = await Promise.all(state.proxies
      .filter((entry) => entry.enabled)
      .map(async (entry) => [entry.id, await checkProxy(entry.url)] as const));
    for (const [id, result] of results) {
      const entry = state.proxies.find((candidate) => candidate.id === id);
      if (entry) entry.health = result;
    }
    return this.save(state);
  }

  selectForSpawn(): string | null {
    const state = this.load();
    if (state.mode === "off") return null;
    if (state.mode === "manual") {
      return state.proxies.find((entry) => entry.id === state.manualId && entry.enabled)?.url ?? null;
    }

    const account = activeAccountKey();
    const usable = state.proxies.filter((entry) => entry.enabled && entry.health?.ok !== false);
    if (usable.length === 0) return null;
    const boundId = state.bindings[account];
    const bound = usable.find((entry) => entry.id === boundId);
    if (bound) return bound.url;

    const chosen = usable.find((entry) => !Object.values(state.bindings).includes(entry.id)) ?? usable[0]!;
    state.bindings[account] = chosen.id;
    try {
      this.save(state);
    } catch (error) {
      console.error("[proxy] failed to persist binding", error);
    }
    return chosen.url;
  }
}
