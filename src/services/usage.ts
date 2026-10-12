import { invokeCommand } from "./bridge";

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

export const usageService = {
  summary: (days: number) => invokeCommand<UsageSummary>("usage_summary", { days }),
};
