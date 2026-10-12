import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { appConfigDir, writeJsonFile } from "./config.js";
import type { Settings } from "./types.js";

export const DEFAULT_SETTINGS: Settings = {
  autoRotate: false,
  autoStart: true,
  opencodeBin: null,
  theme: "dark",
};

export function parseSettings(value: unknown): Settings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return { ...DEFAULT_SETTINGS };
  const raw = value as Record<string, unknown>;
  const autoRotate = raw.autoRotate ?? raw.auto_rotate;
  const autoStart = raw.autoStart ?? raw.auto_start;
  const opencodeBin = raw.opencodeBin ?? raw.opencode_bin;
  const theme = raw.theme;

  return {
    autoRotate: typeof autoRotate === "boolean" ? autoRotate : DEFAULT_SETTINGS.autoRotate,
    autoStart: typeof autoStart === "boolean" ? autoStart : DEFAULT_SETTINGS.autoStart,
    opencodeBin: typeof opencodeBin === "string" && opencodeBin.trim() ? opencodeBin : null,
    theme: typeof theme === "string" && theme.trim() ? theme : DEFAULT_SETTINGS.theme,
  };
}

export class SettingsStore {
  readonly filePath: string;

  constructor(filePath = join(appConfigDir(), "settings.json")) {
    this.filePath = filePath;
  }

  load(): Settings {
    if (!existsSync(this.filePath)) return { ...DEFAULT_SETTINGS };
    try {
      return parseSettings(JSON.parse(readFileSync(this.filePath, "utf8")) as unknown);
    } catch {
      return { ...DEFAULT_SETTINGS };
    }
  }

  save(input: unknown): Settings {
    if (!input || typeof input !== "object" || Array.isArray(input)) {
      throw new Error("settings must be an object");
    }
    const raw = input as Record<string, unknown>;
    const autoRotate = raw.autoRotate ?? raw.auto_rotate;
    const autoStart = raw.autoStart ?? raw.auto_start;
    const opencodeBin = raw.opencodeBin ?? raw.opencode_bin;
    if (typeof autoRotate !== "boolean" || typeof autoStart !== "boolean") {
      throw new Error("settings must include boolean autoRotate and autoStart values");
    }
    if (opencodeBin !== undefined && opencodeBin !== null && typeof opencodeBin !== "string") {
      throw new Error("opencodeBin must be a string or null");
    }
    if (raw.theme !== undefined && typeof raw.theme !== "string") {
      throw new Error("theme must be a string");
    }
    const settings = parseSettings(raw);
    writeJsonFile(this.filePath, settings);
    return settings;
  }
}
