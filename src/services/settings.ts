import { invokeCommand } from "./bridge";

export interface Settings {
  autoRotate: boolean;
  autoStart: boolean;
  opencodeBin?: string | null;
  theme: string;
}

export const settingsService = {
  get: () => invokeCommand<Settings>("settings_get"),
  set: (settings: Settings) => invokeCommand<Settings>("settings_set", { settings }),
};
