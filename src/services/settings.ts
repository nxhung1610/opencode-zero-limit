import { invoke } from "@tauri-apps/api/core";

export interface Settings {
  autoRotate: boolean;
  autoStart: boolean;
  opencodeBin?: string | null;
  theme: string;
}

export const settingsService = {
  get: () => invoke<Settings>("settings_get"),
  set: (settings: Settings) => invoke<Settings>("settings_set", { settings }),
};
