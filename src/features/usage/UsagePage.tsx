import { useCallback, useEffect, useState } from "react";
import { BarChart3, RefreshCw, ShieldAlert } from "lucide-react";
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
  const [autoRotate, setAutoRotate] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setSummary(await usageService.summary(days));
      setError(null);
    } catch (e) {
      setSummary(null);
      setError(String(e));
    }
  }, [days]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    void settingsService
      .get()
      .then((settings) => setAutoRotate(settings.autoRotate))
      .catch((e) => setError(String(e)));
  }, []);

  async function toggleAutoRotate(next: boolean) {
    setBusy(true);
    try {
      const current = await settingsService.get();
      setAutoRotate(next);
      await settingsService.set({ ...current, autoRotate: next });
      setError(null);
    } catch (e) {
      setAutoRotate(!next);
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  const quotaFresh = quota !== null && Date.now() - quota.at < 60 * 60 * 1000;

  return (
    <section className="space-y-4">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <h1 className="flex items-center gap-2 text-lg font-semibold">
            <BarChart3 className="size-5" /> Usage
          </h1>
          <p className="text-sm text-muted-foreground">
            Local counters from opencode's SQLite history. Exact remaining free quota is never
            visible — opencode enforces it server-side, per day, and only reports when you are
            already blocked.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex rounded-md border border-border p-0.5">
            {rangeOptions.map((option) => (
              <button
                key={option.days}
                type="button"
                onClick={() => setDays(option.days)}
                className={
                  days === option.days
                    ? "rounded bg-accent px-2.5 py-1 text-xs font-medium"
                    : "rounded px-2.5 py-1 text-xs text-muted-foreground"
                }
              >
                {option.label}
              </button>
            ))}
          </div>
          <Button size="sm" variant="outline" onClick={() => void load()}>
            <RefreshCw className="size-3.5" /> Refresh
          </Button>
        </div>
      </header>

      <div className="flex items-center justify-between gap-4 rounded-lg border border-border px-4 py-3">
        <div className="text-sm">
          <div className="font-medium">Auto-rotate on quota</div>
          <div className="text-xs text-muted-foreground">
            When a quota is hit, switch to the next console org and restart opencode serve
            automatically.
          </div>
        </div>
        <Switch checked={autoRotate} disabled={busy} onCheckedChange={(v) => void toggleAutoRotate(v)} />
      </div>

      {quotaFresh && (
        <div className="flex items-start gap-3 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3">
          <ShieldAlert className="mt-0.5 size-4 shrink-0 text-amber-600" />
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
                    className="underline hover:text-foreground"
                  >
                    {quota.link}
                  </a>
                </>
              ) : null}
            </div>
          </div>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      {summary ? (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Card label="Requests" value={String(summary.assistantMessages)} />
            <Card label="Sessions" value={String(summary.sessions)} />
            <Card
              label="Tokens (in/out)"
              value={`${formatTokens(summary.inputTokens)} / ${formatTokens(summary.outputTokens)}`}
            />
            <Card
              label="Cache read"
              value={`${formatTokens(summary.cacheReadTokens)} · $${summary.cost.toFixed(2)}`}
            />
          </div>

          {summary.models.length > 0 && (
            <div className="rounded-lg border border-border">
              <div className="border-b border-border px-4 py-2 text-sm font-medium">
                Top models ({summary.days === 1 ? "today" : `last ${summary.days} days`})
              </div>
              <ul className="divide-y divide-border">
                {summary.models.map((model) => (
                  <li
                    key={model.model}
                    className="flex items-center justify-between px-4 py-2 text-sm"
                  >
                    <span className="font-mono text-xs">{model.model}</span>
                    <span className="text-muted-foreground">{model.requests} requests</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      ) : (
        !error && (
          <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
            Loading usage…
          </div>
        )
      )}
    </section>
  );
}

function Card({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-border px-4 py-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="mt-1 text-lg font-semibold tabular-nums">{value}</div>
    </div>
  );
}
