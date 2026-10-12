export interface OpencodeStatus {
  running: boolean;
  healthy: boolean;
  port: number | null;
  version: string | null;
  error: string | null;
}

export interface Settings {
  autoRotate: boolean;
  autoStart: boolean;
  opencodeBin: string | null;
  theme: string;
}

export type ProxyMode = "off" | "manual" | "auto";

export interface ProxyHealth {
  ok: boolean;
  latencyMs: number | null;
  checkedAt: number;
  error: string | null;
}

export interface ProxyEntry {
  id: string;
  label: string;
  url: string;
  enabled: boolean;
  health: ProxyHealth | null;
}

export interface ProxyState {
  mode: ProxyMode;
  manualId: string | null;
  proxies: ProxyEntry[];
  /** Account ID → proxy ID; keeps one sticky IP per account. */
  bindings: Record<string, string>;
}

export interface ModelUsage {
  model: string;
  requests: number;
}

export interface UsageSummary {
  days: number;
  assistantMessages: number;
  userMessages: number;
  sessions: number;
  inputTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  cost: number;
  models: ModelUsage[];
}

export interface ConsoleOrg {
  accountID: string;
  accountEmail: string;
  accountUrl: string;
  orgID: string;
  orgName: string;
  active: boolean;
}

export interface ConsoleConnection {
  id: string;
  label: string;
  active: boolean;
  method: "oauth";
}

export interface ConsoleLoginAttempt {
  attemptID: string;
  url: string;
  instructions: string;
  mode: "auto" | "code";
}

export type ConsoleLoginStatus =
  | { status: "pending" }
  | { status: "complete" }
  | { status: "failed" | "expired"; message: string };

export interface QuotaEvent {
  reason: string;
  provider: string;
  title: string;
  message: string;
  link: string | null;
  sessionId: string;
  attempt: number;
  next: number;
  resetAt: number | null;
  rotatedTo: string | null;
  at: number;
}
