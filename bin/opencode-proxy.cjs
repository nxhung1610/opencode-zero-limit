#!/usr/bin/env node
"use strict";

const { existsSync, realpathSync } = require("node:fs");
const { constants: osConstants } = require("node:os");
const { delimiter, join, resolve } = require("node:path");
const { spawn } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const projectRoot = resolve(__dirname, "..");
const wrapperPath = canonical(__filename);

function canonical(filePath) {
  try {
    return realpathSync(filePath);
  } catch {
    return resolve(filePath);
  }
}

function findRealOpenCodeBinary() {
  const names = process.platform === "win32"
    ? ["opencode.exe", "opencode.cmd", "opencode"]
    : ["opencode"];
  const explicit = [process.env.RELAYDOCK_REAL_OPENCODE_BIN, process.env.OPENCODE_BIN]
    .map((value) => value?.trim())
    .find(Boolean);
  const candidates = [];
  if (explicit) candidates.push(resolve(explicit));
  for (const directory of (process.env.PATH ?? "").split(delimiter).filter(Boolean)) {
    for (const name of names) candidates.push(join(directory, name));
  }

  for (const candidate of candidates) {
    if (!existsSync(candidate) || canonical(candidate) === wrapperPath) continue;
    return candidate;
  }
  throw new Error("Cannot find the real OpenCode CLI after the RelayDock wrapper in PATH.");
}

async function main() {
  const distDir = join(projectRoot, "dist-server");
  const [{ appConfigDir }, { ProxyStore, buildOpenCodeProxyEnv }] = await Promise.all([
    import(pathToFileURL(join(distDir, "config.js")).href),
    import(pathToFileURL(join(distDir, "proxy.js")).href),
  ]);
  const configDir = appConfigDir();
  const proxy = new ProxyStore(join(configDir, "proxies.json")).selectForSpawn();
  const binary = findRealOpenCodeBinary();
  const child = spawn(binary, process.argv.slice(2), {
    env: buildOpenCodeProxyEnv(proxy),
    stdio: "inherit",
    windowsHide: true,
    shell: process.platform === "win32" && /\.cmd$/i.test(binary),
  });

  await new Promise((resolveChild, rejectChild) => {
    child.once("error", rejectChild);
    child.once("close", (code, signal) => {
      process.exitCode = signal
        ? 128 + (osConstants.signals[signal] ?? 1)
        : code ?? 1;
      resolveChild();
    });
  });
}

main().catch((error) => {
  console.error(`[relaydock] ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
