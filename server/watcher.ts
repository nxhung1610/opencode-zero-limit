import { consoleActivate, consoleConnections, consoleOrgs, consoleSwitch } from "./console.js";
import type { OpencodeManager } from "./opencode.js";
import type { SettingsStore } from "./settings.js";
import type { ConsoleConnection, ConsoleOrg, QuotaEvent } from "./types.js";

const ROTATE_COOLDOWN_MS = 120_000;

function delay(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    let timer: NodeJS.Timeout;
    const finish = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    timer = setTimeout(finish, ms);
    signal.addEventListener("abort", finish, { once: true });
    if (signal.aborted) finish();
  });
}

function stringField(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function numberField(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function parseQuotaEvent(value: unknown): Omit<QuotaEvent, "rotatedTo"> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const root = value as Record<string, unknown>;
  if (root.type !== "session.status") return null;
  const properties = root.properties && typeof root.properties === "object"
    ? root.properties as Record<string, unknown>
    : null;
  const status = properties?.status && typeof properties.status === "object"
    ? properties.status as Record<string, unknown>
    : null;
  if (status?.type !== "retry") return null;
  const action = status.action && typeof status.action === "object"
    ? status.action as Record<string, unknown>
    : null;
  const reason = stringField(action?.reason);
  if (reason !== "free_tier_limit" && reason !== "account_rate_limit") return null;

  const now = Date.now();
  const nextUtcMidnight = new Date(now);
  nextUtcMidnight.setUTCHours(24, 0, 0, 0);
  return {
    reason,
    provider: stringField(action?.provider, "opencode"),
    title: stringField(action?.title, "Usage limit reached"),
    message: stringField(action?.message),
    link: typeof action?.link === "string" ? action.link : null,
    sessionId: stringField(properties?.sessionID),
    attempt: Math.max(0, Math.trunc(numberField(status.attempt))),
    next: Math.max(0, numberField(status.next)),
    resetAt: reason === "free_tier_limit" ? nextUtcMidnight.getTime() : null,
    at: now,
  };
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export class QuotaWatcher {
  private controller: AbortController | null = null;
  private task: Promise<void> | null = null;
  private lastRotateAt = 0;
  private listeners = new Set<(event: QuotaEvent) => void>();

  constructor(
    private readonly manager: OpencodeManager,
    private readonly settings: SettingsStore,
  ) {}

  subscribe(listener: (event: QuotaEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  start(): void {
    if (this.task) return;
    const controller = new AbortController();
    this.controller = controller;
    this.task = this.loop(controller.signal).catch((error: unknown) => {
      if (!controller.signal.aborted) console.error("[quota-watcher] stopped:", error);
    }).finally(() => {
      if (this.controller === controller) this.controller = null;
      this.task = null;
    });
  }

  async stop(): Promise<void> {
    this.controller?.abort();
    await this.task;
  }

  private async loop(signal: AbortSignal): Promise<void> {
    while (!signal.aborted) {
      const port = this.manager.getPort();
      if (port === null) {
        await delay(1_000, signal);
        continue;
      }
      try {
        await this.streamOnce(port, signal);
      } catch (error) {
        if (!signal.aborted) {
          console.log(`[quota-watcher] ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      await delay(2_000, signal);
    }
  }

  private async streamOnce(port: number, signal: AbortSignal): Promise<void> {
    const connectController = new AbortController();
    const timeout = setTimeout(() => connectController.abort(), 5_000);
    let response: Response;
    try {
      const eventPath = this.manager.getCliMajorVersion() === 2 ? "/api/event" : "/event";
      response = await fetch(`http://127.0.0.1:${port}${eventPath}`, {
        headers: { Accept: "text/event-stream", ...this.manager.apiHeaders() },
        signal: AbortSignal.any([signal, connectController.signal]),
      });
    } catch (error) {
      throw new Error(`event stream connect failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      clearTimeout(timeout);
    }
    if (!response.ok) throw new Error(`event stream returned ${response.status}`);
    if (!response.body) throw new Error("event stream has no response body");
    console.log(`[quota-watcher] connected to event stream on :${port}`);

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    const onAbort = () => { void reader.cancel().catch(() => undefined); };
    signal.addEventListener("abort", onAbort, { once: true });
    try {
      while (!signal.aborted) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let newline = buffer.indexOf("\n");
        while (newline >= 0) {
          const line = buffer.slice(0, newline).trim();
          buffer = buffer.slice(newline + 1);
          if (line.startsWith("data:")) {
            const data = line.slice(5).trim();
            if (data) {
              try {
                const parsed = parseQuotaEvent(JSON.parse(data) as unknown);
                if (parsed) await this.handle(parsed);
              } catch (error) {
                console.log(`[quota-watcher] bad event payload: ${error instanceof Error ? error.message : String(error)}`);
              }
            }
          }
          newline = buffer.indexOf("\n");
        }
      }
    } finally {
      signal.removeEventListener("abort", onAbort);
      reader.releaseLock();
    }
    if (!signal.aborted) throw new Error("event stream ended");
  }

  private async handle(event: Omit<QuotaEvent, "rotatedTo">): Promise<void> {
    const complete: QuotaEvent = { ...event, rotatedTo: null };
    // Show the limit right away; a second event follows if an account was switched.
    this.emit(complete);
    if (!this.settings.load().autoRotate) return;
    const rotatedTo = await this.rotate();
    if (rotatedTo !== null) this.emit({ ...complete, rotatedTo });
  }

  private emit(event: QuotaEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  // The cooldown covers switch attempts only, so a quota event with nothing to switch to does not block the next one.
  private async rotate(): Promise<string | null> {
    if (Date.now() - this.lastRotateAt < ROTATE_COOLDOWN_MS) return null;

    if (this.manager.getCliMajorVersion() === 2) {
      let connections: ConsoleConnection[];
      try {
        connections = await consoleConnections(this.manager);
      } catch {
        return null;
      }
      if (connections.length < 2) return null;

      const sorted = [...connections].sort((a, b) => compareText(a.label, b.label));
      const activeIndex = sorted.findIndex((connection) => connection.active);
      const next = sorted[activeIndex < 0 ? 0 : (activeIndex + 1) % sorted.length]!;
      if (next.active) return null;
      this.lastRotateAt = Date.now();
      try {
        await consoleActivate(this.manager, next.id);
      } catch {
        return null;
      }
      console.log(`[quota-watcher] rotated to ${next.label}`);
      return next.label;
    }

    let orgs: ConsoleOrg[];
    try {
      orgs = await consoleOrgs(this.manager);
    } catch {
      return null;
    }
    if (orgs.length < 2) return null;

    const sorted = [...orgs].sort((a, b) =>
      compareText(a.accountEmail, b.accountEmail) || compareText(a.orgID, b.orgID));
    const activeIndex = sorted.findIndex((org) => org.active);
    const next = sorted[activeIndex < 0 ? 0 : (activeIndex + 1) % sorted.length]!;
    if (next.active) return null;

    this.lastRotateAt = Date.now();
    try {
      await consoleSwitch(this.manager, next.accountID, next.orgID);
    } catch {
      return null;
    }
    await this.manager.restart();
    console.log(`[quota-watcher] rotated to ${next.orgName} (${next.accountEmail})`);
    return `${next.orgName} · ${next.accountEmail}`;
  }
}
