import { invoke } from "@tauri-apps/api/core";

export type ProxyMode = "off" | "manual" | "auto";

export interface ProxyHealth {
  ok: boolean;
  latencyMs?: number;
  checkedAt: number;
  error?: string;
}

export interface ProxyEntry {
  id: string;
  label: string;
  url: string;
  enabled: boolean;
  health?: ProxyHealth;
}

export interface ProxyState {
  mode: ProxyMode;
  manualId?: string;
  proxies: ProxyEntry[];
  bindings: Record<string, string>;
}

export const proxyService = {
  list: () => invoke<ProxyState>("proxy_list"),
  import: (text: string) => invoke<ProxyState>("proxy_import", { text }),
  remove: (id: string) => invoke<ProxyState>("proxy_remove", { id }),
  setEnabled: (id: string, enabled: boolean) =>
    invoke<ProxyState>("proxy_set_enabled", { id, enabled }),
  setMode: (mode: ProxyMode, manualId?: string) =>
    invoke<ProxyState>("proxy_set_mode", { mode, manualId }),
  checkAll: () => invoke<ProxyState>("proxy_check_all"),
};

export function maskProxyUrl(url: string) {
  return url.replace(/:\/\/([^:/@]+):[^@]+@/, "://$1:•••@");
}
