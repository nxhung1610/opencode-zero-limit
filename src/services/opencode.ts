import { invoke } from "@tauri-apps/api/core";

export interface OpencodeStatus {
  running: boolean;
  healthy: boolean;
  port: number | null;
  version: string | null;
  error: string | null;
}

export const opencodeService = {
  start: () => invoke<OpencodeStatus>("opencode_start"),
  status: () => invoke<OpencodeStatus>("opencode_status"),
  stop: () => invoke<OpencodeStatus>("opencode_stop"),
  restart: () => invoke<OpencodeStatus>("opencode_restart"),
  /** Path of the opencode binary this app will spawn. */
  binary: () => invoke<string | null>("opencode_binary"),
};
