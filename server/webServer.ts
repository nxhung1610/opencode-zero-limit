import { timingSafeEqual, randomBytes } from "node:crypto";
import { createReadStream, existsSync, realpathSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { extname, resolve, sep } from "node:path";
import {
  consoleActivate,
  consoleConnections,
  consoleLoginCancel,
  consoleLoginComplete,
  consoleLoginStart,
  consoleLoginStatus,
  consoleLogout,
} from "./console.js";
import { OpencodeManager } from "./opencode.js";
import { ProxyStore } from "./proxy.js";
import { SettingsStore } from "./settings.js";
import { summary } from "./usage.js";
import type { ProxyMode, QuotaEvent } from "./types.js";
import { QuotaWatcher } from "./watcher.js";

const MAX_BODY_BYTES = 1024 * 1024;

export interface LocalWebServerOptions {
  version: string;
  distDir: string;
  manager: OpencodeManager;
  settings: SettingsStore;
  proxies: ProxyStore;
  watcher: QuotaWatcher;
}

class ApiError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

function json(res: ServerResponse, status: number, value: unknown): void {
  if (res.writableEnded) return;
  const serialized = JSON.stringify(value);
  const body = serialized === undefined ? "null" : serialized;
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Content-Length", Buffer.byteLength(body));
  res.end(body);
}

function headerString(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name.toLowerCase()];
  return typeof value === "string" ? value : undefined;
}

export function requestHeadersAllowed(
  host: string | undefined,
  origin: string | undefined,
  expectedHost: string,
  expectedOrigin: string,
  requireOrigin: boolean,
): boolean {
  if (host !== expectedHost) return false;
  return origin === undefined ? !requireOrigin : origin === expectedOrigin;
}

function tokenMatches(candidate: string | undefined, expected: string): boolean {
  if (!candidate || candidate.length !== expected.length) return false;
  const candidateBytes = Buffer.from(candidate, "utf8");
  const expectedBytes = Buffer.from(expected, "utf8");
  if (candidateBytes.length !== expectedBytes.length) return false;
  return timingSafeEqual(candidateBytes, expectedBytes);
}

function requireString(args: Record<string, unknown>, name: string): string {
  const value = args[name];
  if (typeof value !== "string") throw new ApiError(400, `missing or invalid argument: ${name}`);
  return value;
}

function optionalString(args: Record<string, unknown>, name: string): string | null {
  const value = args[name];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") throw new ApiError(400, `invalid argument ${name}: expected a string or null`);
  return value;
}

function requireBoolean(args: Record<string, unknown>, name: string): boolean {
  const value = args[name];
  if (typeof value !== "boolean") throw new ApiError(400, `missing or invalid argument: ${name}`);
  return value;
}

async function readJsonBody(request: IncomingMessage): Promise<Record<string, unknown>> {
  const contentType = headerString(request, "content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new ApiError(415, "Content-Type must be application/json");
  }
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const part of request) {
    const chunk = Buffer.isBuffer(part) ? part : Buffer.from(part);
    length += chunk.length;
    if (length > MAX_BODY_BYTES) throw new ApiError(413, "request body too large");
    chunks.push(chunk);
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  } catch {
    throw new ApiError(400, "invalid JSON request body");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(400, "request body must be a JSON object");
  }
  return value as Record<string, unknown>;
}

const CONTENT_TYPES: Record<string, string> = {
  ".css": "text/css; charset=utf-8",
  ".gif": "image/gif",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".txt": "text/plain; charset=utf-8",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

export class LocalWebServer {
  private server: Server | null = null;
  private port: number | null = null;
  private readonly token = randomBytes(32).toString("hex");
  private readonly eventClients = new Set<ServerResponse>();
  private unsubscribe: (() => void) | null = null;
  private readonly distDir: string;

  constructor(private readonly options: LocalWebServerOptions) {
    this.distDir = resolve(options.distDir);
  }

  async start(): Promise<string> {
    if (!existsSync(resolve(this.distDir, "index.html"))) {
      throw new Error(`frontend missing at ${this.distDir}; run \`npm run build\` first`);
    }
    if (this.server) throw new Error("local web server is already running");

    this.unsubscribe = this.options.watcher.subscribe((event) => this.broadcast(event));
    const server = createServer((request, response) => {
      void this.handle(request, response).catch((error: unknown) => {
        if (response.writableEnded || response.destroyed) return;
        if (response.headersSent) {
          response.destroy(error instanceof Error ? error : undefined);
          return;
        }
        const status = error instanceof ApiError ? error.status : 500;
        if (status >= 500) console.error("[web] request failed:", error);
        json(response, status, { error: error instanceof Error ? error.message : String(error) });
      });
    });
    server.requestTimeout = 15_000;
    server.headersTimeout = 10_000;
    this.server = server;

    try {
      await new Promise<void>((resolveListen, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          server.removeListener("error", reject);
          resolveListen();
        });
      });
    } catch (error) {
      this.server = null;
      this.unsubscribe?.();
      this.unsubscribe = null;
      throw error;
    }
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("could not read local web server address");
    this.port = address.port;
    return this.url();
  }

  async stop(): Promise<void> {
    this.unsubscribe?.();
    this.unsubscribe = null;
    for (const client of this.eventClients) client.end();
    this.eventClients.clear();
    const server = this.server;
    this.server = null;
    this.port = null;
    if (!server) return;
    await new Promise<void>((resolveClose) => {
      server.close(() => resolveClose());
      server.closeAllConnections();
    });
  }

  url(): string {
    if (this.port === null) throw new Error("local web server is not running");
    return `http://127.0.0.1:${this.port}/`;
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    this.setSecurityHeaders(response);
    const port = this.port;
    if (port === null) {
      json(response, 503, { error: "local web server is stopping" });
      return;
    }
    const expectedHost = `127.0.0.1:${port}`;
    const expectedOrigin = `http://${expectedHost}`;
    const host = headerString(request, "host");
    const origin = headerString(request, "origin");
    const requestUrl = new URL(request.url ?? "/", expectedOrigin);

    if (!requestHeadersAllowed(host, origin, expectedHost, expectedOrigin, false)) {
      json(response, 403, { error: "forbidden host or origin" });
      return;
    }

    if (requestUrl.pathname === "/api/session") {
      if (request.method !== "GET") {
        json(response, 405, { error: "method not allowed" });
        return;
      }
      json(response, 200, { token: this.token });
      return;
    }
    if (requestUrl.pathname === "/api/app-info") {
      if (request.method !== "GET") {
        json(response, 405, { error: "method not allowed" });
        return;
      }
      json(response, 200, { version: this.options.version });
      return;
    }
    if (requestUrl.pathname === "/api/command") {
      if (request.method !== "POST") {
        json(response, 405, { error: "method not allowed" });
        return;
      }
      if (!requestHeadersAllowed(host, origin, expectedHost, expectedOrigin, true)
        || !tokenMatches(headerString(request, "x-relaydock-token"), this.token)) {
        json(response, 403, { error: "forbidden" });
        return;
      }
      const body = await readJsonBody(request);
      if (typeof body.command !== "string") throw new ApiError(400, "missing or invalid argument: command");
      const argsValue = body.args;
      if (argsValue !== undefined && (!argsValue || typeof argsValue !== "object" || Array.isArray(argsValue))) {
        throw new ApiError(400, "args must be a JSON object");
      }
      try {
        const value = await this.dispatch(body.command, (argsValue ?? {}) as Record<string, unknown>);
        json(response, 200, value);
      } catch (error) {
        if (error instanceof ApiError) throw error;
        throw new ApiError(400, error instanceof Error ? error.message : String(error));
      }
      return;
    }
    if (requestUrl.pathname === "/api/events") {
      if (request.method !== "GET") {
        json(response, 405, { error: "method not allowed" });
        return;
      }
      if (!tokenMatches(requestUrl.searchParams.get("token") ?? undefined, this.token)) {
        json(response, 403, { error: "forbidden" });
        return;
      }
      this.addEventClient(response);
      return;
    }
    if (requestUrl.pathname.startsWith("/api/")) {
      json(response, 404, { error: "not found" });
      return;
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      json(response, 405, { error: "method not allowed" });
      return;
    }
    await this.serveStatic(requestUrl.pathname, request.method === "HEAD", response);
  }

  private async dispatch(command: string, args: Record<string, unknown>): Promise<unknown> {
    switch (command) {
      case "opencode_start": return this.options.manager.start();
      case "opencode_status": return this.options.manager.status();
      case "opencode_stop": return this.options.manager.stop();
      case "opencode_restart": return this.options.manager.restart();
      case "console_connections": return consoleConnections(this.options.manager);
      case "console_login_start": return consoleLoginStart(this.options.manager);
      case "console_login_status": return consoleLoginStatus(this.options.manager, requireString(args, "attemptID"));
      case "console_login_complete": return consoleLoginComplete(
        this.options.manager, requireString(args, "attemptID"), requireString(args, "code"),
      );
      case "console_login_cancel": return consoleLoginCancel(this.options.manager, requireString(args, "attemptID"));
      case "console_activate": return consoleActivate(this.options.manager, requireString(args, "credentialID"));
      case "console_logout": return consoleLogout(this.options.manager, requireString(args, "credentialID"));
      case "usage_summary": {
        const days = args.days;
        if (typeof days !== "number" || !Number.isInteger(days)) throw new ApiError(400, "missing or invalid argument: days");
        return summary(Math.min(365, Math.max(1, Math.trunc(days))));
      }
      case "settings_get": return this.options.settings.load();
      case "settings_set": {
        if (!args.settings || typeof args.settings !== "object" || Array.isArray(args.settings)) {
          throw new ApiError(400, "missing or invalid argument: settings");
        }
        return this.options.settings.save(args.settings);
      }
      case "opencode_binary": return this.options.manager.resolveBinary();
      case "proxy_list": return this.options.proxies.load();
      case "proxy_import": return this.options.proxies.import(requireString(args, "text"));
      case "proxy_remove": return this.options.proxies.remove(requireString(args, "id"));
      case "proxy_set_enabled": return this.options.proxies.setEnabled(
        requireString(args, "id"), requireBoolean(args, "enabled"),
      );
      case "proxy_set_mode": {
        const mode = requireString(args, "mode");
        if (mode !== "off" && mode !== "manual" && mode !== "auto") {
          throw new ApiError(400, "invalid proxy mode");
        }
        return this.options.proxies.setMode(mode as ProxyMode, optionalString(args, "manualId"));
      }
      case "proxy_check_all": return this.options.proxies.checkAll();
      default: throw new ApiError(404, `unknown command: ${command}`);
    }
  }

  private addEventClient(response: ServerResponse): void {
    response.statusCode = 200;
    response.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    response.setHeader("Connection", "keep-alive");
    response.setHeader("X-Accel-Buffering", "no");
    response.flushHeaders();
    response.write(": connected\n\n");
    this.eventClients.add(response);
    const heartbeat = setInterval(() => {
      if (!response.destroyed && !response.writableEnded) response.write(": keep-alive\n\n");
    }, 20_000);
    heartbeat.unref();
    response.once("close", () => {
      clearInterval(heartbeat);
      this.eventClients.delete(response);
    });
  }

  private broadcast(event: QuotaEvent): void {
    const data = JSON.stringify(event);
    for (const client of this.eventClients) {
      if (!client.destroyed && !client.writableEnded) client.write(`event: quota\ndata: ${data}\n\n`);
    }
  }

  private async serveStatic(pathname: string, headOnly: boolean, response: ServerResponse): Promise<void> {
    let decodedPath: string;
    try {
      decodedPath = decodeURIComponent(pathname);
    } catch {
      json(response, 400, { error: "invalid path" });
      return;
    }
    const requested = resolve(this.distDir, `.${decodedPath}`);
    if (requested !== this.distDir && !requested.startsWith(`${this.distDir}${sep}`)) {
      json(response, 403, { error: "forbidden path" });
      return;
    }
    let filePath = requested;
    if (!existsSync(filePath) || !statSync(filePath).isFile()) filePath = resolve(this.distDir, "index.html");
    const realRoot = realpathSync(this.distDir);
    filePath = realpathSync(filePath);
    if (filePath !== realRoot && !filePath.startsWith(`${realRoot}${sep}`)) {
      json(response, 403, { error: "forbidden path" });
      return;
    }
    const contentType = CONTENT_TYPES[extname(filePath).toLowerCase()] ?? "application/octet-stream";
    const size = statSync(filePath).size;
    response.statusCode = 200;
    response.setHeader("Content-Type", contentType);
    response.setHeader("Content-Length", size);
    if (headOnly) {
      response.end();
      return;
    }
    await new Promise<void>((resolveStream, reject) => {
      const stream = createReadStream(filePath);
      stream.once("error", reject);
      stream.once("end", resolveStream);
      stream.pipe(response);
    });
  }

  private setSecurityHeaders(response: ServerResponse): void {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("Referrer-Policy", "no-referrer");
    response.setHeader("X-Frame-Options", "DENY");
    response.setHeader(
      "Content-Security-Policy",
      "default-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
    );
  }
}
