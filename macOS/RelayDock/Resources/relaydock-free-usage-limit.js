// RelayDock-managed plugin. RelayDock regenerates this file during install.

const DAY_MS = 86_400_000;
const MAX_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;

// OpenCode's free-usage counters reset at 00:00 UTC, not 24 hours after the
// error. When the provider does not supply an explicit retry window, wait
// only until the next UTC midnight instead of over-quarantining for a full
// day (a limit seen at 23:59 should clear in a minute, not tomorrow night).
function defaultCooldownMs(now = Date.now()) {
  const remainder = ((now % DAY_MS) + DAY_MS) % DAY_MS;
  return remainder === 0 ? DAY_MS : DAY_MS - remainder;
}

function parseJSON(value) {
  if (typeof value !== "string" || value.length > 256 * 1024) return undefined;
  const trimmed = value.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}

function values(root) {
  const result = [];
  const pending = [{ value: root, depth: 0 }];
  const seen = new Set();
  while (pending.length && result.length < 256) {
    const { value, depth } = pending.pop();
    if (depth > 12 || value == null) continue;
    result.push(value);
    if (typeof value === "string") {
      const parsed = parseJSON(value);
      if (parsed !== undefined) pending.push({ value: parsed, depth: depth + 1 });
      continue;
    }
    if (typeof value !== "object" || seen.has(value)) continue;
    seen.add(value);
    for (const child of Object.values(value)) pending.push({ value: child, depth: depth + 1 });
  }
  return result;
}

function isFreeUsageLimitError(error) {
  return values(error).some((value) => {
    if (typeof value === "string") {
      const lower = value.toLowerCase();
      return lower.includes("freeusagelimiterror")
        || lower.includes("provider.free-limit")
        || lower.includes("free usage limit reached");
    }
    if (!value || typeof value !== "object") return false;
    const marker = [value.name, value.type, value.code].filter(Boolean).join(" ").toLowerCase();
    return marker.includes("freeusagelimiterror") || marker.includes("provider.free-limit");
  });
}

function retryAfterMs(error, now = Date.now()) {
  const found = values(error);
  // Prefer the provider's explicit millisecond field over a generic
  // Retry-After header if both are present.
  for (const value of found) {
    if (!value || typeof value !== "object") continue;
    for (const [rawKey, rawValue] of Object.entries(value)) {
      if (rawKey.toLowerCase().replaceAll(/[_-]/g, "") !== "retryafterms") continue;
      const number = Number(rawValue);
      if (Number.isFinite(number) && number > 0) return number;
    }
  }
  for (const value of found) {
    if (!value || typeof value !== "object") continue;
    for (const [rawKey, rawValue] of Object.entries(value)) {
      const key = rawKey.toLowerCase().replaceAll(/[_-]/g, "");
      const number = Number(rawValue);
      if ((key === "retryafterseconds" || key === "retryafter")
          && Number.isFinite(number) && number > 0) return number * 1000;
      if (key === "resetatms" && Number.isFinite(number)) return number - now;
      if (key === "resetat" && Number.isFinite(number)) {
        return (number > 1e12 ? number : number * 1000) - now;
      }
      if (key === "resetat" && typeof rawValue === "string") {
        const parsed = Date.parse(rawValue);
        if (Number.isFinite(parsed)) return parsed - now;
      }
      if (key === "retryafter" && typeof rawValue === "string" && !Number.isFinite(number)) {
        const parsed = Date.parse(rawValue);
        if (Number.isFinite(parsed)) return parsed - now;
      }
      if (key === "retry-after" && typeof rawValue === "string") {
        const seconds = Number(rawValue);
        if (Number.isFinite(seconds) && seconds > 0) return seconds * 1000;
        const parsed = Date.parse(rawValue);
        if (Number.isFinite(parsed)) return parsed - now;
      }
    }
  }
  return defaultCooldownMs(now);
}

function edgePortFromEnvironment() {
  if (typeof process === "undefined") return undefined;
  const env = process.env ?? {};
  // Test All's one-shot OpenCode run goes directly through one selected proxy,
  // not through Edge's shared pool listener. Its plugin report still goes to
  // Edge and names the exact entry that the request tested.
  if (env.RELAYDOCK_TEST_PROXY_ID) {
    const port = Number(env.RELAYDOCK_TEST_EDGE_PORT);
    if (Number.isInteger(port) && port > 0 && port <= 65535) return port;
  }
  for (const key of ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]) {
    const raw = env[key];
    if (!raw) continue;
    try {
      const proxy = new URL(raw);
      if (proxy.protocol !== "http:") continue;
      if (!["127.0.0.1", "localhost", "::1", "[::1]"].includes(proxy.hostname)) continue;
      const port = Number(proxy.port);
      if (Number.isInteger(port) && port > 0 && port <= 65535) return port;
    } catch {
      // Ignore unrelated or malformed proxy environment variables.
    }
  }
  return undefined;
}

async function handleEvent(event) {
  if (event?.type !== "session.error") return;
  const error = event.properties?.error;
  if (!isFreeUsageLimitError(error)) return;
  const port = edgePortFromEnvironment();
  if (!port) return;

  const cooldownMs = Math.min(MAX_COOLDOWN_MS, Math.max(1_000, Math.ceil(retryAfterMs(error))));
  const params = new URLSearchParams({ retryAfterMs: String(cooldownMs) });
  if (typeof process !== "undefined" && process.env?.RELAYDOCK_TEST_PROXY_ID) {
    params.set("entryID", process.env.RELAYDOCK_TEST_PROXY_ID);
  }
  const url = `http://127.0.0.1:${port}/__relaydock/free-usage-limit?${params}`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1_500);
  try {
    await fetch(url, {
      method: "POST",
      headers: { Accept: "text/plain" },
      signal: controller.signal,
    });
  } catch {
    // Reporting is best-effort; an OpenCode session should not fail because
    // RelayDock is stopped or the Edge proxy cannot be reached.
  } finally {
    clearTimeout(timeout);
  }
}

// Keep V1 compatibility for OpenCode 1.x, which discovers named plugin
// functions. OpenCode 2.x requires a default definition with an id and setup.
export const RelayDockFreeUsageLimit = async () => ({
  event: async ({ event }) => handleEvent(event),
});

// Exposed for the repository's Node regression test; OpenCode ignores it.
export { defaultCooldownMs };

export default {
  id: "relaydock-free-usage-limit",
  setup(ctx) {
    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          await handleEvent(event);
        }
      } catch {
        // Event stream shutdown is expected when OpenCode unloads the plugin.
      }
    })();
    return () => controller.abort();
  },
};
