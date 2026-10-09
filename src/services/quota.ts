import type { OpencodeStatus } from "./opencode";

/**
 * Emitted by the Rust watcher (`quota` event) when opencode reports a
 * free-tier or account/Go usage limit over SSE (`session.status` → retry).
 */
export interface QuotaEvent {
  reason: "free_tier_limit" | "account_rate_limit" | string;
  provider: string;
  title: string;
  message: string;
  link?: string;
  sessionId: string;
  attempt: number;
  next: number;
  /** epoch ms — next UTC midnight for free-tier limits */
  resetAt?: number;
  /** set when auto-rotate moved to another account/org */
  rotatedTo?: string;
  at: number;
}

export type { OpencodeStatus };
