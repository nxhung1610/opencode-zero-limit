#!/usr/bin/env node
const { existsSync, readFileSync } = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const projectRoot = path.resolve(__dirname, "..");
const args = process.argv.slice(2);

function printUsage() {
  console.log(readFileSync(path.join(__dirname, "usage.txt"), "utf8").trimEnd());
}

if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
  printUsage();
  process.exit(0);
}
if (args[0] !== "serve" && args[0] !== "proxy") {
  console.error(`Unknown command: ${args[0]}`);
  printUsage();
  process.exit(2);
}

const serverEntry = path.join(projectRoot, "dist-server", "main.js");
if (!existsSync(serverEntry)) {
  console.error("RelayDock backend is not built. Run `npm run build` from the checkout first.");
  process.exit(1);
}

import(pathToFileURL(serverEntry).href)
  .then(({ runCli }) => runCli(args))
  .catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
