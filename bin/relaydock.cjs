#!/usr/bin/env node
const { existsSync } = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const projectRoot = path.resolve(__dirname, "..");
const args = process.argv.slice(2);

function printUsage() {
  console.log(`Usage: relaydock <command> [options]

Commands:
  serve       Start the local web app and open it in your browser
  proxy install-wrapper    Route default opencode commands through RelayDock's proxy
  proxy uninstall-wrapper  Remove the RelayDock OpenCode wrapper

Options:
  --no-open   Start the server without opening a browser
  -h, --help  Show this help

The web server listens on loopback and stops when this process exits.`);
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
