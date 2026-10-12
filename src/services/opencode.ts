import { invokeCommand } from "./bridge";

export interface OpencodeStatus {
  running: boolean;
  healthy: boolean;
  port: number | null;
  version: string | null;
  error: string | null;
}

export const opencodeService = {
  start: () => invokeCommand<OpencodeStatus>("opencode_start"),
  status: () => invokeCommand<OpencodeStatus>("opencode_status"),
  stop: () => invokeCommand<OpencodeStatus>("opencode_stop"),
  restart: () => invokeCommand<OpencodeStatus>("opencode_restart"),
  /** Path of the opencode binary this app will spawn. */
  binary: () => invokeCommand<string | null>("opencode_binary"),
};
