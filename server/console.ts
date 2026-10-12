import type { OpencodeManager } from "./opencode.js";
import type {
  ConsoleConnection,
  ConsoleLoginAttempt,
  ConsoleLoginStatus,
  ConsoleOrg,
  OpencodeStatus,
} from "./types.js";

const CONSOLE_INTEGRATION_ID = "opencode";

type JsonRecord = Record<string, unknown>;

function portOrThrow(manager: OpencodeManager): number {
  const port = manager.getPort();
  if (port === null) throw new Error("opencode serve is not running");
  return port;
}

function requireV2(manager: OpencodeManager): number {
  const port = portOrThrow(manager);
  if (manager.getCliMajorVersion() !== 2) {
    throw new Error("browser-based Console sign-in requires OpenCode CLI v2");
  }
  return port;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function responseData(value: unknown): unknown {
  return isRecord(value) && "data" in value ? value.data : value;
}

async function apiRequest(manager: OpencodeManager, path: string, init: RequestInit = {}): Promise<Response> {
  const port = portOrThrow(manager);
  const headers = new Headers(init.headers);
  for (const [name, value] of Object.entries(manager.apiHeaders())) headers.set(name, value);
  if (init.body !== undefined && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");

  try {
    return await fetch(`http://127.0.0.1:${port}${path}`, {
      ...init,
      headers,
      signal: AbortSignal.timeout(8_000),
    });
  } catch (error) {
    throw new Error(`request failed: ${error instanceof Error ? error.message : String(error)}`);
  }
}

async function apiJson<T>(manager: OpencodeManager, path: string, init: RequestInit = {}): Promise<T> {
  const response = await apiRequest(manager, path, init);
  const text = await response.text().catch(() => "");
  if (!response.ok) throw new Error(`OpenCode API returned ${response.status}${text ? `: ${text}` : ""}`);
  let body: unknown;
  try {
    body = text ? JSON.parse(text) as unknown : null;
  } catch (error) {
    throw new Error(`invalid OpenCode API response: ${error instanceof Error ? error.message : String(error)}`);
  }
  return responseData(body) as T;
}

export async function consoleOrgs(manager: OpencodeManager): Promise<ConsoleOrg[]> {
  const response = await apiJson<{ orgs?: unknown }>(manager, "/experimental/console/orgs");
  if (!Array.isArray(response.orgs)) throw new Error("invalid console orgs response");
  return response.orgs as ConsoleOrg[];
}

export async function consoleSwitch(manager: OpencodeManager, accountId: string, orgId: string): Promise<void> {
  const response = await apiRequest(manager, "/experimental/console/switch", {
    method: "POST",
    body: JSON.stringify({ accountID: accountId, orgID: orgId }),
  });
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`switch rejected: ${body || response.status}`);
  }
}

async function consoleIntegration(manager: OpencodeManager): Promise<unknown> {
  // /api/info can report healthy before v2 finishes registering its integrations.
  for (let attempt = 0; attempt < 12; attempt += 1) {
    try {
      return await apiJson<unknown>(manager, `/api/integration/${CONSOLE_INTEGRATION_ID}`);
    } catch (error) {
      const isNotReady = error instanceof Error && error.message.includes("IntegrationNotFoundError");
      if (!isNotReady || attempt === 11) throw error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  throw new Error("OpenCode Console integration did not become available");
}

async function consoleCredentials(manager: OpencodeManager): Promise<JsonRecord[]> {
  requireV2(manager);
  const result = await apiJson<unknown>(manager, "/api/credential");
  if (!Array.isArray(result)) throw new Error("invalid OpenCode credential response");
  return result.filter(isRecord);
}

export async function consoleConnections(manager: OpencodeManager): Promise<ConsoleConnection[]> {
  const credentials = await consoleCredentials(manager);
  return credentials.flatMap((credential) => {
    if (credential.integrationID !== CONSOLE_INTEGRATION_ID || typeof credential.id !== "string") return [];
    return [{
      id: credential.id,
      label: typeof credential.label === "string" && credential.label.trim()
        ? credential.label
        : "OpenCode Console account",
      active: credential.active === true,
      method: "oauth" as const,
    }];
  });
}

async function consoleCredential(manager: OpencodeManager, credentialID: string): Promise<JsonRecord> {
  if (!credentialID.trim() || credentialID.length > 256) throw new Error("invalid OpenCode Console credential ID");
  const credentials = await consoleCredentials(manager);
  const credential = credentials.find((candidate) => candidate.id === credentialID);
  if (!credential || credential.integrationID !== CONSOLE_INTEGRATION_ID) {
    throw new Error("OpenCode Console credential not found");
  }
  return credential;
}

export async function consoleActivate(manager: OpencodeManager, credentialID: string): Promise<OpencodeStatus> {
  await consoleCredential(manager, credentialID);
  const id = encodeURIComponent(credentialID);
  const response = await apiRequest(manager, `/api/credential/${id}/activate`, { method: "POST" });
  if (!response.ok) throw new Error(`OpenCode could not activate the Console account (${response.status})`);
  return manager.status();
}

export async function consoleLogout(manager: OpencodeManager, credentialID: string): Promise<string> {
  const credential = await consoleCredential(manager, credentialID);
  const id = encodeURIComponent(credentialID);
  const response = await apiRequest(manager, `/api/credential/${id}`, { method: "DELETE" });
  if (!response.ok) throw new Error(`OpenCode could not remove the Console account (${response.status})`);
  const label = typeof credential.label === "string" ? credential.label : "OpenCode Console account";
  return `Removed ${label}`;
}

export async function consoleLoginStart(manager: OpencodeManager): Promise<ConsoleLoginAttempt> {
  requireV2(manager);
  const integration = await consoleIntegration(manager);
  if (!isRecord(integration) || !Array.isArray(integration.methods)) {
    throw new Error("OpenCode Console integration is unavailable");
  }
  const methods = integration.methods.filter(isRecord);
  const method = methods.find((candidate) => candidate.type === "oauth" && candidate.id === "device")
    ?? methods.find((candidate) => candidate.type === "oauth");
  if (!method || typeof method.id !== "string") throw new Error("OpenCode Console does not offer browser sign-in");

  const attempt = await apiJson<unknown>(manager, `/api/integration/${CONSOLE_INTEGRATION_ID}/connect/oauth`, {
    method: "POST",
    body: JSON.stringify({ methodID: method.id }),
  });
  if (!isRecord(attempt)) throw new Error("invalid OpenCode sign-in response");
  const attemptID = typeof attempt.attemptID === "string" ? attempt.attemptID : attempt.id;
  if (typeof attemptID !== "string" || typeof attempt.url !== "string") {
    throw new Error("OpenCode did not return a browser sign-in link");
  }
  let signInURL: URL;
  try {
    signInURL = new URL(attempt.url);
  } catch {
    throw new Error("OpenCode returned an invalid browser sign-in link");
  }
  if (signInURL.protocol !== "https:" || signInURL.username || signInURL.password) {
    throw new Error("OpenCode returned an insecure browser sign-in link");
  }
  return {
    attemptID,
    url: signInURL.toString(),
    instructions: typeof attempt.instructions === "string" ? attempt.instructions : "Complete sign-in in your browser.",
    mode: attempt.mode === "code" ? "code" : "auto",
  };
}

function oauthPath(attemptID: string): string {
  if (!attemptID.trim() || attemptID.length > 256) throw new Error("invalid OpenCode sign-in attempt ID");
  return `/api/integration/${CONSOLE_INTEGRATION_ID}/connect/oauth/${encodeURIComponent(attemptID)}`;
}

export async function consoleLoginStatus(manager: OpencodeManager, attemptID: string): Promise<ConsoleLoginStatus> {
  requireV2(manager);
  const status = await apiJson<unknown>(manager, oauthPath(attemptID));
  if (!isRecord(status)) throw new Error("invalid OpenCode sign-in status");
  if (status.status === "pending" || status.status === "complete") return { status: status.status };
  if (status.status === "failed" || status.status === "expired") {
    return {
      status: status.status,
      message: typeof status.message === "string" ? status.message : `OpenCode sign-in ${status.status}`,
    };
  }
  throw new Error("unknown OpenCode sign-in status");
}

export async function consoleLoginComplete(manager: OpencodeManager, attemptID: string, code: string): Promise<void> {
  requireV2(manager);
  if (!code.trim() || code.length > 2048) throw new Error("invalid sign-in code");
  const response = await apiRequest(manager, `${oauthPath(attemptID)}/complete`, {
    method: "POST",
    body: JSON.stringify({ code }),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`OpenCode could not complete sign-in (${response.status})${text ? `: ${text}` : ""}`);
  }
}

export async function consoleLoginCancel(manager: OpencodeManager, attemptID: string): Promise<void> {
  requireV2(manager);
  const response = await apiRequest(manager, oauthPath(attemptID), { method: "DELETE" });
  if (!response.ok && response.status !== 404) {
    throw new Error(`OpenCode could not cancel sign-in (${response.status})`);
  }
}
