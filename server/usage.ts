import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { openCodeDatabasePath } from "./config.js";
import type { ModelUsage, UsageSummary } from "./types.js";

export function dbPath(): string {
  return openCodeDatabasePath();
}

function asNumber(value: unknown): number {
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function asCount(value: unknown): number {
  return Math.max(0, Math.trunc(asNumber(value)));
}

export function summary(days: number): UsageSummary {
  const path = dbPath();
  if (!existsSync(path)) throw new Error(`opencode database not found at ${path}`);

  let database: DatabaseSync;
  try {
    database = new DatabaseSync(path, { readOnly: true });
  } catch (error) {
    throw new Error(`cannot open ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }

  const normalizedDays = Math.min(365, Math.max(1, Math.trunc(days)));
  const since = Date.now() - normalizedDays * 86_400_000;
  try {
    const aggregate = database.prepare(`
      SELECT
        COUNT(CASE WHEN json_extract(data,'$.role') = 'assistant' THEN 1 END) AS assistantMessages,
        COUNT(CASE WHEN json_extract(data,'$.role') = 'user' THEN 1 END) AS userMessages,
        COUNT(DISTINCT session_id) AS sessions,
        SUM(COALESCE(json_extract(data,'$.tokens.input'), 0)) AS inputTokens,
        SUM(COALESCE(json_extract(data,'$.tokens.output'), 0)) AS outputTokens,
        SUM(COALESCE(json_extract(data,'$.tokens.reasoning'), 0)) AS reasoningTokens,
        SUM(COALESCE(json_extract(data,'$.tokens.cache.read'), 0)) AS cacheReadTokens,
        SUM(COALESCE(json_extract(data,'$.tokens.cache.write'), 0)) AS cacheWriteTokens,
        SUM(COALESCE(json_extract(data,'$.cost'), 0)) AS cost
      FROM message WHERE time_created >= ?
    `).get(since) as Record<string, unknown> | undefined;

    const models = database.prepare(`
      SELECT COALESCE(json_extract(data,'$.modelID'), 'unknown') AS model, COUNT(*) AS requests
      FROM message
      WHERE json_extract(data,'$.role') = 'assistant' AND time_created >= ?
      GROUP BY 1 ORDER BY 2 DESC LIMIT 10
    `).all(since) as Array<Record<string, unknown>>;

    return {
      days: normalizedDays,
      assistantMessages: asCount(aggregate?.assistantMessages),
      userMessages: asCount(aggregate?.userMessages),
      sessions: asCount(aggregate?.sessions),
      inputTokens: asCount(aggregate?.inputTokens),
      outputTokens: asCount(aggregate?.outputTokens),
      reasoningTokens: asCount(aggregate?.reasoningTokens),
      cacheReadTokens: asCount(aggregate?.cacheReadTokens),
      cacheWriteTokens: asCount(aggregate?.cacheWriteTokens),
      cost: asNumber(aggregate?.cost),
      models: models.map((row): ModelUsage => ({
        model: typeof row.model === "string" ? row.model : "unknown",
        requests: asCount(row.requests),
      })),
    };
  } catch (error) {
    throw new Error(`cannot read OpenCode usage database: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    database.close();
  }
}

export function activeAccountKey(): string {
  const path = dbPath();
  if (!existsSync(path)) return "anonymous";
  let database: DatabaseSync | undefined;
  try {
    database = new DatabaseSync(path, { readOnly: true });
    const row = database.prepare("SELECT active_account_id FROM account_state WHERE id = 1").get() as
      | { active_account_id?: unknown }
      | undefined;
    return typeof row?.active_account_id === "string" && row.active_account_id
      ? row.active_account_id
      : "anonymous";
  } catch {
    return "anonymous";
  } finally {
    database?.close();
  }
}
