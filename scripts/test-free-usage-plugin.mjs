#!/usr/bin/env node
// Regression test for the OpenCode free-usage plugin's UTC-midnight fallback.
// The plugin is an ES module with a .js extension, so copy it to a temporary
// .mjs file before importing it in Node.

import assert from "node:assert/strict";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(root, "macOS/RelayDock/Resources/relaydock-free-usage-limit.js");
const directory = await mkdtemp(join(tmpdir(), "relaydock-plugin-test-"));
const target = join(directory, "relaydock-free-usage-limit.mjs");

try {
  await copyFile(source, target);
  const { defaultCooldownMs } = await import(pathToFileURL(target).href);

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

  console.log(`free-usage plugin fallback: ${cases.length} cases passed`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
