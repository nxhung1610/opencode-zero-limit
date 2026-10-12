import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { appConfigDir } from "./config.js";
import { OpencodeManager } from "./opencode.js";
import { ProxyStore } from "./proxy.js";
import { installOpenCodeProxyWrapper, uninstallOpenCodeProxyWrapper } from "./proxyWrapper.js";
import { SettingsStore } from "./settings.js";
import { LocalWebServer } from "./webServer.js";
import { QuotaWatcher } from "./watcher.js";

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export function printUsage(): void {
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

function readVersion(): string {
  const packageJson = JSON.parse(readFileSync(join(PROJECT_ROOT, "package.json"), "utf8")) as { version?: unknown };
  return typeof packageJson.version === "string" ? packageJson.version : "0.0.0";
}

function openBrowser(url: string): void {
  const command = process.platform === "darwin"
    ? "open"
    : process.platform === "win32"
      ? "cmd.exe"
      : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  try {
    const child = spawn(command, args, { detached: true, stdio: "ignore", windowsHide: true });
    child.once("error", (error) => console.warn(`[web] could not open browser: ${error.message}`));
    child.unref();
  } catch (error) {
    console.warn(`[web] could not open browser: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export async function runCli(args: string[]): Promise<void> {
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }
  if (args[0] === "proxy") {
    try {
      if (args.length !== 2 || (args[1] !== "install-wrapper" && args[1] !== "uninstall-wrapper")) {
        console.error("Usage: relaydock proxy <install-wrapper|uninstall-wrapper>");
        process.exitCode = 2;
        return;
      }
      if (args[1] === "install-wrapper") {
        const result = installOpenCodeProxyWrapper(PROJECT_ROOT);
        console.log(`${result.alreadyInstalled ? "Already installed" : "Installed"} OpenCode wrapper: ${result.path}`);
        console.log("Open a new terminal or run `rehash` before checking `command -v opencode`.");
      } else {
        const result = uninstallOpenCodeProxyWrapper(PROJECT_ROOT);
        console.log(result.removed ? `Removed OpenCode wrapper: ${result.path}` : "OpenCode wrapper was not installed.");
      }
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    }
    return;
  }
  if (args[0] !== "serve") {
    console.error(`Unknown command: ${args[0]}`);
    printUsage();
    process.exitCode = 2;
    return;
  }
  const options = args.slice(1);
  const invalidOption = options.find((option) => option !== "--no-open");
  if (invalidOption) {
    console.error(`Unknown option: ${invalidOption}`);
    printUsage();
    process.exitCode = 2;
    return;
  }

  const configDir = appConfigDir();
  const settings = new SettingsStore(join(configDir, "settings.json"));
  const proxies = new ProxyStore(join(configDir, "proxies.json"));
  const manager = new OpencodeManager(settings, () => proxies.selectForSpawn());
  const watcher = new QuotaWatcher(manager, settings);
  const distDir = process.env.RELAYDOCK_DIST_DIR
    ? resolve(process.env.RELAYDOCK_DIST_DIR)
    : join(PROJECT_ROOT, "dist");
  const web = new LocalWebServer({ version: readVersion(), distDir, manager, settings, proxies, watcher });

  let url: string;
  try {
    url = await web.start();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
    return;
  }

  watcher.start();
  const readyFile = process.env.RELAYDOCK_READY_FILE;
  if (readyFile) {
    try {
      writeFileSync(readyFile, url, { mode: 0o600 });
    } catch (error) {
      console.error(`[web] could not write ready file ${readyFile}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  console.log(`Local app: ${url}`);
  console.log(`WEB_SERVER_READY=${url}`);

  if (settings.load().autoStart && process.env.RELAYDOCK_NO_AUTOSTART === undefined) {
    void manager.start().then((status) => {
      if (status.error) console.log(`[opencode] serve failed: ${status.error}`);
    }).catch((error: unknown) => {
      console.log(`[opencode] serve failed: ${error instanceof Error ? error.message : String(error)}`);
    });
  }
  if (!options.includes("--no-open")) openBrowser(url);

  await new Promise<void>((resolveSignal) => {
    let stopping = false;
    const stop = () => {
      if (stopping) return;
      stopping = true;
      void (async () => {
        await watcher.stop();
        try {
          await web.stop();
        } finally {
          await manager.stop();
        }
      })().catch((error: unknown) => {
        console.error(`[shutdown] ${error instanceof Error ? error.message : String(error)}`);
      }).finally(resolveSignal);
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  });
}
