#!/usr/bin/env node
// Regression test for the OpenCode free-usage plugin's UTC-midnight fallback.
// The plugin is an ES module with a .js extension, so copy it to a temporary
// .mjs file before importing it in Node.

import assert from "node:assert/strict";
import { appendFile, copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "macOS/RelayDock/Resources/relaydock-free-usage-limit.js");
const directory = await mkdtemp(join(tmpdir(), "relaydock-plugin-test-"));
const target = join(directory, "relaydock-free-usage-limit.mjs");

try {
  await copyFile(source, target);
  // The shipped plugin deliberately exports only its V1 entry point, so the
  // OpenCode 1.x loader cannot mistake test helpers for plugins. Add them to
  // the temporary test copy instead.
  await appendFile(
    target,
    "\nexport { defaultCooldownMs, isFreeUsageLimitText, cooldownFromBody };\n"
  );
  const { defaultCooldownMs, cooldownFromBody } = await import(pathToFileURL(target).href);

  const cases = [
    // 2026-10-25T23:59:00Z -> one minute until midnight.
    [1_792_972_740_000, 60_000],
    // 2026-10-25T23:59:59.500Z -> half a second; the caller clamps this to 1s.
    [1_792_972_799_500, 500],
    // Exactly midnight is the start of a new day, so the full day remains.
    [1_792_972_800_000, 86_400_000],
    // Noon UTC -> twelve hours.
    [1_792_929_600_000, 43_200_000],
  ];

  for (const [now, expected] of cases) {
    assert.equal(defaultCooldownMs(now), expected, `fallback at ${new Date(now).toISOString()}`);
  }

  // A structured reset that has already passed is a real window, not a
  // missing one: keep it so the reporter can clamp it to one second.
  assert.equal(cooldownFromBody('{"resetAtMs": 0}', 1_000_000), -1_000_000);
  assert.equal(cooldownFromBody('{"retryAfterMs": 0}', 1_000_000), 0);
  assert.equal(cooldownFromBody('{"retryAfter": 0}', 1_000_000), 0);
  assert.equal(cooldownFromBody('{"retryAfterMs": null}', 1_000_000), undefined);
  assert.equal(cooldownFromBody('{"resetAtMs": null}', 1_000_000), undefined);
  assert.equal(cooldownFromBody('{"message":"no reset"}', 1_000_000), undefined);

  // The V2 retry hook is the part that keeps a free-limit response away from
  // the CLI. Drive it through the real plugin setup so the test covers hook
  // registration, the Edge report, and the retry decision together.
  const plugin = (await import(pathToFileURL(target).href)).default;
  const hooks = {};
  const controller = new AbortController();
  const originalFetch = globalThis.fetch;
  const originalProxy = process.env.HTTP_PROXY;
  process.env.HTTP_PROXY = "http://127.0.0.1:57211";
  const reported = [];

  const ctx = {
    session: {
      hook: async (name, callback) => {
        hooks[name] = callback;
        return { dispose: async () => {} };
      },
    },
    event: {
      subscribe: async ({ signal }) => (async function* () {
        await new Promise((done) => signal.addEventListener("abort", done, { once: true }));
      })(),
    },
  };

  const dispose = await plugin.setup(ctx);
  try {
    assert.equal(typeof hooks["http.response"], "function", "http.response hook is registered");
    assert.equal(typeof hooks.retry, "function", "retry hook is registered");

    globalThis.fetch = async (url) => {
      reported.push(String(url));
      return new Response(JSON.stringify({ status: "retrying", entryID: "px_a", rotate: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    // An error OpenCode already classified: report it, then retry once Edge
    // confirms another proxy is available.
    const direct = { sessionID: "ses_direct", attempt: 1, error: { status: 429, name: "FreeUsageLimitError" } };
    await hooks.retry(direct);
    assert.deepEqual(direct.decision, { retry: true, delay: 1_500 });
    assert.equal(reported.length, 1);
    assert.match(reported[0], /\/__relaydock\/free-usage-limit\?/);
    assert.match(reported[0], /retryAfterMs=\d+/);

    // The response hook reports first; the retry hook reuses that decision
    // instead of sending a second report.
    const response = new Response(
      JSON.stringify({ error: { type: "provider.free-limit", message: "Free usage limit reached" } }),
      { status: 429, headers: { "retry-after": "120" } }
    );
    await hooks["http.response"]({ sessionID: "ses_cached", response });
    assert.equal(reported.length, 2);
    const cached = { sessionID: "ses_cached", attempt: 2, error: { status: 429 } };
    await hooks.retry(cached);
    assert.deepEqual(cached.decision, { retry: true, delay: 1_500 });

    // The response-hook decision is consumed once: a later ordinary 429 in
    // the same session must not inherit it.
    const laterRateLimit = {
      sessionID: "ses_cached",
      attempt: 3,
      error: { status: 429, name: "RateLimitedError" },
    };
    await hooks.retry(laterRateLimit);
    assert.equal(laterRateLimit.decision, undefined);

    // A structured reset in the past is clamped to one second instead of
    // falling back to the next UTC midnight.
    const pastReset = new Response(
      JSON.stringify({ resetAtMs: Date.now() - 60_000, error: { type: "provider.free-limit" } }),
      { status: 429 }
    );
    await hooks["http.response"]({ sessionID: "ses_past_reset", response: pastReset });
    assert.match(reported.at(-1), /retryAfterMs=1000/);

    // An explicit Retry-After: 0 also clamps to one second, not midnight.
    const zeroHeader = new Response(
      JSON.stringify({ error: { type: "provider.free-limit" } }),
      { status: 429, headers: { "retry-after": "0" } }
    );
    await hooks["http.response"]({ sessionID: "ses_zero_header", response: zeroHeader });
    assert.match(reported.at(-1), /retryAfterMs=1000/);

    // Only the beginning of a 429 body is inspected. A marker beyond the
    // 64 KiB cap must not trigger a report.
    const beforeCap = reported.length;
    const oversized = new Response(
      "x".repeat(70_000) + JSON.stringify({ error: { type: "provider.free-limit" } }),
      { status: 429 }
    );
    await hooks["http.response"]({ sessionID: "ses_oversized", response: oversized });
    assert.equal(reported.length, beforeCap);

    // No alternative proxy -> surface the error instead of looping.
    globalThis.fetch = async () => new Response(JSON.stringify({ rotate: false }), { status: 200 });
    const exhausted = { sessionID: "ses_exhausted", attempt: 1, error: { status: 429, name: "FreeUsageLimitError" } };
    await hooks.retry(exhausted);
    assert.equal(exhausted.decision, undefined);

    // Retry attempts are bounded even while Edge says it can rotate.
    globalThis.fetch = async () => new Response(JSON.stringify({ rotate: true }), { status: 200 });
    const bounded = { sessionID: "ses_bounded", attempt: 4, error: { status: 429, name: "FreeUsageLimitError" } };
    await hooks.retry(bounded);
    assert.equal(bounded.decision, undefined);

    // Non-free-limit 429s are left alone.
    const unrelated = { sessionID: "ses_unrelated", attempt: 1, error: { status: 429, name: "RateLimitedError" } };
    await hooks.retry(unrelated);
    assert.equal(unrelated.decision, undefined);
  } finally {
    globalThis.fetch = originalFetch;
    if (originalProxy === undefined) delete process.env.HTTP_PROXY;
    else process.env.HTTP_PROXY = originalProxy;
    controller.abort();
    await dispose();
  }

  console.log(`free-usage plugin: ${cases.length} fallback cases and retry policy passed`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
