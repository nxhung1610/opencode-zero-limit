import { invokeCommand } from "./bridge";

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
  list: () => invokeCommand<ProxyState>("proxy_list"),
  import: (text: string) => invokeCommand<ProxyState>("proxy_import", { text }),
  remove: (id: string) => invokeCommand<ProxyState>("proxy_remove", { id }),
  setEnabled: (id: string, enabled: boolean) =>
    invokeCommand<ProxyState>("proxy_set_enabled", { id, enabled }),
  setMode: (mode: ProxyMode, manualId?: string) =>
    invokeCommand<ProxyState>("proxy_set_mode", { mode, manualId }),
  checkAll: () => invokeCommand<ProxyState>("proxy_check_all"),
};

export function maskProxyUrl(url: string) {
  return url.replace(/:\/\/([^:/@]+):[^@]+@/, "://$1:•••@");
}
