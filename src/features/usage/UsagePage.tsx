import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowRight, RefreshCw, ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { usageService, type UsageSummary } from "@/services/usage";
import { settingsService } from "@/services/settings";
import type { QuotaEvent } from "@/services/quota";

interface UsagePageProps {
  quota: QuotaEvent | null;
}

const rangeOptions = [
  { days: 1, label: "Today" },
  { days: 7, label: "7 days" },
  { days: 30, label: "30 days" },
];

function formatTokens(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}

function formatReset(at: number | undefined) {
  if (!at) return null;
  const date = new Date(at);
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function UsagePage({ quota }: UsagePageProps) {
  const [days, setDays] = useState(1);
  const [summary, setSummary] = useState<UsageSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [autoRotate, setAutoRotate] = useState(false);
  const [settingsLoading, setSettingsLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const requestId = useRef(0);

  const load = useCallback(async () => {
    const currentRequest = ++requestId.current;
    setLoading(true);
    setError(null);
    try {
      const next = await usageService.summary(days);
      if (currentRequest !== requestId.current) return;
      setSummary(next);
      setError(null);
      setLastUpdated(new Date());
    } catch (e) {
      if (currentRequest !== requestId.current) return;
      setSummary(null);
      setError(String(e));
    } finally {
      if (currentRequest === requestId.current) setLoading(false);
    }
  }, [days]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    void settingsService
      .get()
      .then((settings) => setAutoRotate(settings.autoRotate))
      .catch((e) => setSettingsError(String(e)))
      .finally(() => setSettingsLoading(false));
  }, []);

  async function toggleAutoRotate(next: boolean) {
    setBusy(true);
    setSettingsError(null);
    setNotice(null);
    try {
      const current = await settingsService.get();
      await settingsService.set({ ...current, autoRotate: next });
      setAutoRotate(next);
      setNotice(`Auto-rotation ${next ? "enabled" : "disabled"}.`);
    } catch (e) {
      setSettingsError(String(e));
    } finally {
      setBusy(false);
    }
  }

  const quotaFresh = quota !== null && Date.now() - quota.at < 60 * 60 * 1000;
  const hasUsage = summary !== null && [
    summary.assistantMessages,
    summary.userMessages,
    summary.sessions,
    summary.inputTokens,
    summary.outputTokens,
    summary.reasoningTokens,
    summary.cacheReadTokens,
    summary.cacheWriteTokens,
    summary.cost,
    summary.models.length,
  ].some((value) => value > 0);

  return (
    <section aria-busy={loading || busy || settingsLoading} className="page-stack">
      <header className="page-heading">
        <div className="page-heading__copy">
          <h1 className="page-title">Usage</h1>
          <p className="page-description">
            Local counters from opencode's SQLite history. Exact remaining free quota is never
            visible — opencode enforces it server-side, per day, and only reports when you are
            already blocked.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div role="group" aria-label="Usage time range" className="mode-selector">
            {rangeOptions.map((option) => (
              <button
                key={option.days}
                type="button"
                aria-pressed={days === option.days}
                onClick={() => setDays(option.days)}
                className={`mode-option${days === option.days ? " mode-option--selected" : ""}`}
              >
                {option.label}
              </button>
            ))}
          </div>
          <div className="flex flex-col items-end gap-1">
            <Button size="sm" variant="outline" disabled={loading} onClick={() => void load()}>
              <RefreshCw aria-hidden="true" className={`size-3.5 ${loading ? "animate-spin" : ""}`} />
              {loading ? "Refreshing…" : "Refresh"}
            </Button>
            <span aria-live="polite" className="text-[11px] text-muted-foreground">
              {lastUpdated ? `Updated ${lastUpdated.toLocaleTimeString()}` : "Not refreshed yet"}
            </span>
          </div>
        </div>
      </header>

      <div className="usage-layout">
        <div className="usage-layout__main">
          {quotaFresh && (
            <div role="status" aria-live="polite" className="quota-event">
              <ShieldAlert aria-hidden="true" className="mt-0.5 size-4 shrink-0" />
              <div className="min-w-0 text-sm">
                <div className="font-medium">
                  {quota.title}
                  {quota.rotatedTo ? ` — rotated to ${quota.rotatedTo}` : ""}
                </div>
                <div className="text-xs text-muted-foreground">
                  {quota.message}
                  {quota.resetAt ? ` Resets ${formatReset(quota.resetAt)}.` : ""}
                  {quota.link ? (
                    <>
                      {" "}
                      <a
                        href={quota.link}
                        target="_blank"
                        rel="noreferrer"
                        className="rounded-sm underline hover:text-foreground focus-visible:outline-2 focus-visible:outline-solid focus-visible:outline-ring focus-visible:outline-offset-2 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
                      >
                        {quota.link}
                      </a>
                    </>
                  ) : null}
                </div>
              </div>
            </div>
          )}

          {notice && (
            <div role="status" aria-live="polite" className="status-message status-message--positive">
              {notice}
            </div>
          )}

          {settingsError && (
            <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
              Auto-rotation setting unavailable: {settingsError}
            </div>
          )}
          {error && (
            <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
              <span>{error}</span>
              {!summary && (
                <Button size="sm" variant="outline" disabled={loading} onClick={() => void load()}>
                  Try again
                </Button>
              )}
            </div>
          )}

          {summary ? (
            <div className="usage-data">
              {!hasUsage ? (
                <div role="status" className="empty-state">
                  No usage recorded for this period yet.
                </div>
              ) : (
                <>
                  <section className="usage-data-section" aria-labelledby="usage-activity-heading">
                    <header className="usage-data-section__header">
                      <h2 id="usage-activity-heading" className="usage-data-section__title">Activity</h2>
                      <span className="usage-data-section__meta">
                        {summary.days === 1 ? "Today" : `Last ${summary.days} days`} · Local counters
                      </span>
                    </header>
                    <dl className="usage-data-list">
                      <div className="usage-data-list__row">
                        <dt>Sessions</dt>
                        <dd>{summary.sessions}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Assistant messages</dt>
                        <dd>{summary.assistantMessages}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>User messages</dt>
                        <dd>{summary.userMessages}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Estimated cost</dt>
                        <dd>${summary.cost.toFixed(2)}</dd>
                      </div>
                    </dl>
                  </section>

                  <section className="usage-data-section" aria-labelledby="usage-token-heading">
                    <header className="usage-data-section__header">
                      <h2 id="usage-token-heading" className="usage-data-section__title">Token breakdown</h2>
                      <span className="usage-data-section__meta">Recorded by opencode</span>
                    </header>
                    <dl className="usage-data-list">
                      <div className="usage-data-list__row">
                        <dt>Input</dt>
                        <dd>{formatTokens(summary.inputTokens)}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Output</dt>
                        <dd>{formatTokens(summary.outputTokens)}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Reasoning</dt>
                        <dd>{formatTokens(summary.reasoningTokens)}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Cache read</dt>
                        <dd>{formatTokens(summary.cacheReadTokens)}</dd>
                      </div>
                      <div className="usage-data-list__row">
                        <dt>Cache write</dt>
                        <dd>{formatTokens(summary.cacheWriteTokens)}</dd>
                      </div>
                    </dl>
                  </section>

                  <section className="usage-data-section" aria-labelledby="usage-models-heading">
                    <header className="usage-data-section__header">
                      <h2 id="usage-models-heading" className="usage-data-section__title">Models</h2>
                      <span className="usage-data-section__meta">
                        {summary.days === 1 ? "Today" : `Last ${summary.days} days`}
                      </span>
                    </header>
                    {summary.models.length > 0 ? (
                      <ul className="usage-model-list">
                        {summary.models.map((model) => (
                          <li key={model.model} className="usage-model-row">
                            <span className="font-mono text-xs">{model.model}</span>
                            <span className="text-muted-foreground">{model.requests} requests</span>
                          </li>
                        ))}
                      </ul>
                    ) : (
                      <div role="status" className="empty-state">
                        No model breakdown is available for this period.
                      </div>
                    )}
                  </section>
                </>
              )}
            </div>
          ) : loading ? (
            <div role="status" aria-live="polite" className="empty-state">
              Loading usage…
            </div>
          ) : null}
        </div>

        <aside className="usage-layout__aside" aria-label="Quota behavior">
          <section className="switchyard-panel rotation-policy" aria-labelledby="usage-auto-rotate-label">
            <div className="rotation-policy__header">
              <div className="rotation-policy__copy">
                <h2 id="usage-auto-rotate-label" className="rotation-policy__title">Auto-rotate on quota</h2>
                <p id="usage-auto-rotate-description" className="rotation-policy__description">
                  When enabled, a reported quota limit activates the next saved OpenCode Console connection.
                </p>
                <div role="status" aria-live="polite" className="rotation-policy__state" data-enabled={autoRotate}>
                  {settingsLoading ? "Loading setting…" : autoRotate ? "Enabled" : "Disabled"}
                </div>
              </div>
              <Switch
                aria-labelledby="usage-auto-rotate-label"
                aria-describedby="usage-auto-rotate-description"
                checked={autoRotate}
                disabled={busy || settingsLoading}
                onCheckedChange={(v) => void toggleAutoRotate(v)}
              />
            </div>
            <div className="rotation-flow" role="group" aria-label="Automatic recovery sequence when enabled">
              <span className="rotation-flow__step">Quota limit reported</span>
              <ArrowRight aria-hidden="true" className="rotation-flow__arrow" />
              <span className="rotation-flow__step">Activate next account</span>
              <ArrowRight aria-hidden="true" className="rotation-flow__arrow" />
              <span className="rotation-flow__step">Continue locally</span>
            </div>
          </section>
        </aside>
      </div>
    </section>
  );
}
