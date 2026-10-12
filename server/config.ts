import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { chmodSync, mkdirSync, renameSync, writeFileSync } from "node:fs";

/**
 * Keep the former Tauri bundle identifier as the data directory namespace.
 * Changing the local host must not strand existing settings/proxy files.
 */
export const LEGACY_CONFIG_NAMESPACE = "com.nxhung.opencodezerolimit";

export function appConfigDir(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.RELAYDOCK_CONFIG_DIR?.trim();
  if (override) return resolve(override);

  const home = homedir();
  if (process.platform === "darwin") {
    return join(home, "Library", "Application Support", LEGACY_CONFIG_NAMESPACE);
  }
  if (process.platform === "win32") {
    return join(env.APPDATA || join(home, "AppData", "Roaming"), LEGACY_CONFIG_NAMESPACE);
  }
  return join(env.XDG_CONFIG_HOME || join(home, ".config"), LEGACY_CONFIG_NAMESPACE);
}

export function openCodeDatabasePath(env: NodeJS.ProcessEnv = process.env): string {
  const xdgDataHome = env.XDG_DATA_HOME?.trim();
  if (xdgDataHome) return join(xdgDataHome, "opencode", "opencode.db");
  return join(env.HOME || homedir(), ".local", "share", "opencode", "opencode.db");
}

export function writeJsonFile(filePath: string, value: unknown): void {
  const directory = dirname(filePath);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (process.platform !== "win32") chmodSync(directory, 0o700);
  const tempPath = `${filePath}.${process.pid}.tmp`;
  writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  if (process.platform !== "win32") chmodSync(tempPath, 0o600);
  renameSync(tempPath, filePath);
}
