import type { QuotaEvent } from "./quota";

export interface AppInfo {
  version: string;
}

let webTokenPromise: Promise<string> | null = null;

async function webToken(refresh = false): Promise<string> {
  if (refresh) webTokenPromise = null;
  if (!webTokenPromise) {
    webTokenPromise = fetch("/api/session", { cache: "no-store" }).then(async (response) => {
      if (!response.ok) throw new Error(`Local session request failed (${response.status})`);
      const body = (await response.json()) as { token?: unknown };
      if (typeof body.token !== "string" || body.token.length < 32) {
        throw new Error("Local server returned an invalid session token");
      }
      return body.token;
    }).catch((error: unknown) => {
      webTokenPromise = null;
      throw error;
    });
  }
  return webTokenPromise;
}

async function webRequest<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = await webToken(attempt > 0);
    const response = await fetch("/api/command", {
      method: "POST",
      cache: "no-store",
      headers: {
        "Content-Type": "application/json",
        "X-RelayDock-Token": token,
      },
      body: JSON.stringify({ command, args: args ?? {} }),
    });

    if (response.status === 403 && attempt === 0) continue;
    const payload = (await response.json().catch(() => null)) as { error?: unknown } | T | null;
    if (!response.ok) {
      const message = payload && typeof payload === "object" && "error" in payload && typeof payload.error === "string"
        ? payload.error
        : `Local command failed (${response.status})`;
      throw new Error(message);
    }
    return payload as T;
  }
  throw new Error("Local server session expired; reload the page and try again");
}

export function invokeCommand<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  return webRequest<T>(command, args);
}

export async function getAppInfo(): Promise<AppInfo> {
  const response = await fetch("/api/app-info", { cache: "no-store" });
  if (!response.ok) throw new Error(`Local app info request failed (${response.status})`);
  return (await response.json()) as AppInfo;
}

export async function listenQuota(handler: (event: QuotaEvent) => void): Promise<() => void> {
  const token = await webToken();
  const source = new EventSource(`/api/events?token=${encodeURIComponent(token)}`);
  source.addEventListener("quota", (event) => {
    try {
      handler(JSON.parse((event as MessageEvent<string>).data) as QuotaEvent);
    } catch (error) {
      console.error("Invalid quota event from local server", error);
    }
  });
  return () => source.close();
}
