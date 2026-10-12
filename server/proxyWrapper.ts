import {
  existsSync,
  lstatSync,
  mkdirSync,
  realpathSync,
  symlinkSync,
  unlinkSync,
} from "node:fs";
import { homedir } from "node:os";
import { delimiter, join, resolve } from "node:path";

function canonical(filePath: string): string {
  try {
    return realpathSync(filePath);
  } catch {
    return resolve(filePath);
  }
}

function findOpenCodeInPath(pathValue: string, skippedPath: string): string | null {
  const names = process.platform === "win32"
    ? ["opencode.exe", "opencode.cmd", "opencode"]
    : ["opencode"];
  for (const directory of pathValue.split(delimiter).filter(Boolean)) {
    for (const name of names) {
      const candidate = join(directory, name);
      if (existsSync(candidate) && canonical(candidate) !== skippedPath) return candidate;
    }
  }
  return null;
}

export function installOpenCodeProxyWrapper(projectRoot: string): { path: string; alreadyInstalled: boolean } {
  if (process.platform === "win32") throw new Error("The OpenCode PATH wrapper currently supports macOS and Linux only.");
  const wrapperPath = resolve(projectRoot, "bin", "opencode-proxy.cjs");
  if (!existsSync(wrapperPath)) throw new Error(`RelayDock wrapper is missing: ${wrapperPath}`);

  const binDirectory = resolve(homedir(), ".local", "bin");
  const targetPath = join(binDirectory, "opencode");
  const wrapperRealPath = canonical(wrapperPath);
  let existing: ReturnType<typeof lstatSync> | null = null;
  try {
    existing = lstatSync(targetPath);
  } catch {
    // The wrapper is not installed yet.
  }
  if (existing) {
    if (existing.isSymbolicLink() && canonical(targetPath) === wrapperRealPath) {
      return { path: targetPath, alreadyInstalled: true };
    }
    throw new Error(`Refusing to replace an existing file at ${targetPath}.`);
  }

  const pathDirectories = (process.env.PATH ?? "").split(delimiter).filter(Boolean).map((directory) => resolve(directory));
  const wrapperDirectoryIndex = pathDirectories.indexOf(binDirectory);
  const existingCli = findOpenCodeInPath(process.env.PATH ?? "", wrapperRealPath);
  if (!existingCli) throw new Error("OpenCode CLI was not found in PATH; install it before enabling the wrapper.");
  const cliDirectoryIndex = pathDirectories.indexOf(resolve(existingCli, ".."));
  if (wrapperDirectoryIndex < 0 || (cliDirectoryIndex >= 0 && wrapperDirectoryIndex >= cliDirectoryIndex)) {
    throw new Error(`Add ${binDirectory} before the OpenCode CLI in PATH, then retry.`);
  }

  mkdirSync(binDirectory, { recursive: true, mode: 0o755 });
  symlinkSync(wrapperPath, targetPath);
  return { path: targetPath, alreadyInstalled: false };
}

export function uninstallOpenCodeProxyWrapper(projectRoot: string): { path: string; removed: boolean } {
  if (process.platform === "win32") throw new Error("The OpenCode PATH wrapper currently supports macOS and Linux only.");
  const wrapperPath = resolve(projectRoot, "bin", "opencode-proxy.cjs");
  const targetPath = join(homedir(), ".local", "bin", "opencode");
  let existing: ReturnType<typeof lstatSync> | null = null;
  try {
    existing = lstatSync(targetPath);
  } catch {
    return { path: targetPath, removed: false };
  }
  if (!existing.isSymbolicLink() || canonical(targetPath) !== canonical(wrapperPath)) {
    throw new Error(`Refusing to remove a file not managed by RelayDock: ${targetPath}`);
  }
  unlinkSync(targetPath);
  return { path: targetPath, removed: true };
}
