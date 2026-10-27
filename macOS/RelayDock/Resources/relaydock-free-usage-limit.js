// RelayDock-managed plugin. RelayDock regenerates this file during install.

const DAY_MS = 86_400_000;
const MAX_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;
// OpenCode retries on the same provider by default only for transient
// failures. A free-usage limit is terminal, so the plugin turns it into a
// bounded retry after Edge has quarantined the proxy that delivered it.
// OpenCode's retry events carry the attempt that is about to start, and the
// first retry is attempt 2. Allowing attempts up to 3 therefore means three
// requests in total (the original plus two retries).
const MAX_FREE_LIMIT_ATTEMPTS = 3;
// Edge closes the tunnel that carried the 429 before this delay elapses, so
// the retry below has to open a fresh CONNECT and reach another exit IP.
const RETRY_DELAY_MS = 1_500;
const RESPONSE_MEMORY_MS = 60_000;
const REPORT_TIMEOUT_MS = 1_500;
// A provider error page should be tiny. Read only the beginning of a 429 body
// so a hostile or broken response cannot make the plugin buffer megabytes.
const RESPONSE_BODY_LIMIT = 64 * 1024;

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

function isFreeUsageLimitText(text) {
  if (typeof text !== "string") return false;
  const lower = text.toLowerCase();
  return lower.includes("freeusagelimiterror")
    || lower.includes("provider.free-limit")
    || lower.includes("free usage limit reached");
}

function isFreeUsageLimitError(error) {
  return values(error).some((value) => {
    if (typeof value === "string") return isFreeUsageLimitText(value);
    if (!value || typeof value !== "object") return false;
    const marker = [value.name, value.type, value.code].filter(Boolean).join(" ").toLowerCase();
    return marker.includes("freeusagelimiterror") || marker.includes("provider.free-limit");
  });
}

function numericValue(rawValue) {
  if (typeof rawValue === "number") return Number.isFinite(rawValue) ? rawValue : undefined;
  if (typeof rawValue !== "string") return undefined;
  const trimmed = rawValue.trim();
  if (trimmed === "") return undefined;
  const number = Number(trimmed);
  return Number.isFinite(number) ? number : undefined;
}

function structuredCooldownMs(error, now = Date.now()) {
  const found = values(error);
  // Prefer the provider's explicit millisecond field over a generic
  // Retry-After header if both are present.
  for (const value of found) {
    if (!value || typeof value !== "object") continue;
    for (const [rawKey, rawValue] of Object.entries(value)) {
      if (rawKey.toLowerCase().replaceAll(/[_-]/g, "") !== "retryafterms") continue;
      const number = numericValue(rawValue);
      if (number !== undefined && number >= 0) return number;
    }
  }
  for (const value of found) {
    if (!value || typeof value !== "object") continue;
    for (const [rawKey, rawValue] of Object.entries(value)) {
      const key = rawKey.toLowerCase().replaceAll(/[_-]/g, "");
      const number = numericValue(rawValue);
      if ((key === "retryafterseconds" || key === "retryafter")
          && number !== undefined && number >= 0) return number * 1000;
      if (key === "resetatms" && number !== undefined) return number - now;
      if (key === "resetat" && number !== undefined) {
        return (number > 1e12 ? number : number * 1000) - now;
      }
      if (key === "resetat" && typeof rawValue === "string") {
        const parsed = Date.parse(rawValue);
        if (Number.isFinite(parsed)) return parsed - now;
      }
      if (key === "retryafter" && typeof rawValue === "string" && number === undefined) {
        const parsed = Date.parse(rawValue);
        if (Number.isFinite(parsed)) return parsed - now;
      }
    }
  }
  return undefined;
}

function retryAfterMs(error, now = Date.now()) {
  return structuredCooldownMs(error, now) ?? defaultCooldownMs(now);
}

function normalizedCooldown(value) {
  return Math.min(MAX_COOLDOWN_MS, Math.max(1_000, Math.ceil(value)));
}

function cooldownFromHeaders(headers) {
  if (!headers) return undefined;
  // Treat an explicit zero as "retry now"; the reporter clamps it to one
  // second. Missing headers must not be mistaken for zero.
  const rawMilliseconds = headers.get?.("retry-after-ms");
  if (rawMilliseconds != null && rawMilliseconds !== "") {
    const milliseconds = Number(rawMilliseconds);
    if (Number.isFinite(milliseconds) && milliseconds >= 0) return milliseconds;
  }
  const rawSeconds = headers.get?.("retry-after");
  if (rawSeconds != null && rawSeconds !== "") {
    const seconds = Number(rawSeconds);
    if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000;
  }
  return undefined;
}

function cooldownFromBody(text, now = Date.now()) {
  const parsed = parseJSON(text);
  if (parsed === undefined) return undefined;
  // Keep a zero or past reset as a value so the reporter can clamp it to one
  // second. Only a body with no structured window returns undefined, which
  // lets the caller fall back to the next UTC midnight.
  return structuredCooldownMs(parsed, now);
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

function explicitTestEntry() {
  if (typeof process === "undefined") return undefined;
  const entry = process.env?.RELAYDOCK_TEST_PROXY_ID;
  return typeof entry === "string" && entry.length > 0 ? entry : undefined;
}

// Reports the limit to Edge and returns whether Edge can route the retry
// through a different proxy right now. `rotate` is true only when Edge has an
// eligible alternative and has quarantined the entry that delivered the 429.
async function reportFreeUsageLimit(cooldownMs, rotate) {
  const port = edgePortFromEnvironment();
  if (!port) return false;

  const params = new URLSearchParams({ retryAfterMs: String(normalizedCooldown(cooldownMs)) });
  if (rotate) params.set("retry", "1");
  const entry = explicitTestEntry();
  if (entry) params.set("entryID", entry);
  const url = `http://127.0.0.1:${port}/__relaydock/free-usage-limit?${params}`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REPORT_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { Accept: "application/json" },
      signal: controller.signal,
    });
    if (!response.ok) return false;
    const body = await response.text();
    const parsed = parseJSON(body);
    return parsed?.rotate === true;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

// The retry hook runs after OpenCode classifies the failure. The response
// hook usually reported it first; this function only reports when it did not.
const responseLimits = new Map();

function rememberResponseLimit(sessionID, cooldownMs, rotate) {
  const now = Date.now();
  responseLimits.set(sessionID, { at: now, cooldownMs, rotate });
  if (responseLimits.size > 64) {
    for (const [key, value] of responseLimits) {
      if (now - value.at > RESPONSE_MEMORY_MS) responseLimits.delete(key);
    }
  }
}

function takeResponseLimit(sessionID) {
  const entry = responseLimits.get(sessionID);
  responseLimits.delete(sessionID);
  if (!entry || Date.now() - entry.at > RESPONSE_MEMORY_MS) return undefined;
  return entry;
}

// Read a cloned response body with a byte cap. The original response keeps
// its own branch of the tee, so cancelling this reader after the cap does not
// consume what OpenCode still needs.
async function readResponseText(response, limit = RESPONSE_BODY_LIMIT) {
  const body = response?.body;
  if (!body || typeof body.getReader !== "function") return "";
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let bytes = 0;
  try {
    while (bytes < limit) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;
      const remaining = limit - bytes;
      const chunk = value.byteLength > remaining ? value.subarray(0, remaining) : value;
      text += decoder.decode(chunk, { stream: true });
      bytes += chunk.byteLength;
      if (chunk.byteLength < value.byteLength) break;
    }
    return text + decoder.decode();
  } finally {
    // Do not await cancel: a tee branch can stay pending until the other
    // branch (the response OpenCode still owns) is consumed. Releasing this
    // reader is enough to stop our side from buffering more bytes.
    void reader.cancel().catch(() => {});
  }
}

async function inspectResponse(event) {
  const response = event?.response;
  if (!response || response.status !== 429) return;
  // A new 429 supersedes any remembered decision for this session.
  responseLimits.delete(event.sessionID);
  let text = "";
  try {
    text = await readResponseText(response.clone());
  } catch {
    return;
  }
  if (!isFreeUsageLimitText(text)) return;

  const cooldownMs = cooldownFromHeaders(response.headers)
    ?? cooldownFromBody(text)
    ?? defaultCooldownMs();
  const rotate = await reportFreeUsageLimit(cooldownMs, true);
  rememberResponseLimit(event.sessionID, cooldownMs, rotate);
}

async function decideRetry(event) {
  const error = event?.error;
  // Consume the response-hook decision: it belongs to this failure only.
  const cached = takeResponseLimit(event?.sessionID);
  const limited = isFreeUsageLimitError(error) || (error?.status === 429 && cached !== undefined);
  if (!limited) return;

  const cooldownMs = cached?.cooldownMs ?? retryAfterMs(error);
  const rotate = cached?.rotate ?? await reportFreeUsageLimit(cooldownMs, true);
  if (!rotate) return;

  const attempt = Number(event.attempt);
  if (Number.isFinite(attempt) && attempt > MAX_FREE_LIMIT_ATTEMPTS) return;
  event.decision = { retry: true, delay: RETRY_DELAY_MS };
}

async function handleEvent(event) {
  if (event?.type !== "session.error") return;
  const error = event.properties?.error;
  if (!isFreeUsageLimitError(error)) return;
  const cooldownMs = cooldownFromBody(JSON.stringify(error)) ?? retryAfterMs(error);
  await reportFreeUsageLimit(cooldownMs, false);
}

// Keep V1 compatibility for OpenCode 1.x, which discovers named plugin
// functions. V1 has no retry hook, so it still reports the limit and pauses
// the proxy; only V2 can retry without a user action.
const RelayDockFreeUsageLimitPlugin = async () => ({
  event: async ({ event }) => handleEvent(event),
});

export const RelayDockFreeUsageLimit = RelayDockFreeUsageLimitPlugin;

export default {
  id: "relaydock-free-usage-limit",
  // OpenCode 1.x requires the default export to carry `server()`; newer V1
  // loaders ignore the named-export fallback once `id` is present. Keep the
  // same factory on both paths so only one hook set is registered.
  server: RelayDockFreeUsageLimitPlugin,
  async setup(ctx) {
    const registrations = [];
    if (typeof ctx?.session?.hook === "function") {
      try {
        registrations.push(await ctx.session.hook("http.response", inspectResponse));
        registrations.push(await ctx.session.hook("retry", decideRetry));
      } catch {
        // Older OpenCode 2 builds do not expose session hooks, or reject the
        // retry hook. Undo a partial registration and fall back to reporting
        // through the event stream below.
        for (const registration of registrations) {
          try {
            await registration?.dispose?.();
          } catch {
            // Best effort: the host disposes plugin registrations on unload.
          }
        }
        registrations.length = 0;
      }
    }

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
    return async () => {
      controller.abort();
      responseLimits.clear();
      for (const registration of registrations) {
        try {
          await registration?.dispose?.();
        } catch {
          // Best effort: shutdown must not throw into the host.
        }
      }
    };
  },
};
