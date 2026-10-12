import { useCallback, useEffect, useState } from "react";
import { Activity, KeyRound, Plus, RefreshCw, Server, Trash2, Waypoints } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { cn } from "cn";
import { maskProxyUrl, proxyService, type ProxyMode, type ProxyState } from "@/services/proxy";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";

interface ProxyPageProps {
  status: OpencodeStatus | null;
  onStatus: (status: OpencodeStatus) => void;
}

const modes: { id: ProxyMode; label: string; hint: string }[] = [
  { id: "off", label: "Off", hint: "Direct connection" },
  { id: "auto", label: "Auto", hint: "Sticky per account; skips failed health checks" },
  { id: "manual", label: "Manual", hint: "One fixed proxy" },
];

export function ProxyPage({ status, onStatus }: ProxyPageProps) {
  const [state, setState] = useState<ProxyState | null>(null);
  const [importText, setImportText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [checking, setChecking] = useState(false);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setState(await proxyService.list());
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  /** Proxy env only applies to a freshly spawned serve. */
  async function applyAndRestart(change: string) {
    if (!status?.running) {
      const nextStep = status === null
        ? "If opencode serve is already running, restart it to apply."
        : "It will apply when opencode serve next starts.";
      setNotice(`${change} ${nextStep}`);
      return;
    }
    setNotice(`${change} Restarting opencode serve…`);
    onStatus(await opencodeService.restart());
    setNotice(`${change} opencode serve restarted.`);
  }

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await action();
      setError(null);
    } catch (e) {
      setNotice(null);
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  const setMode = (mode: ProxyMode, manualId?: string) =>
    run(async () => {
      setState(await proxyService.setMode(mode, manualId));
      const label = modes.find((option) => option.id === mode)?.label ?? mode;
      await applyAndRestart(`Proxy mode set to ${label}.`);
    });

  const setManual = (id: string) => setMode("manual", id);

  const doImport = () =>
    run(async () => {
      const next = await proxyService.import(importText);
      setState(next);
      setImportText("");
      await applyAndRestart(`Imported — pool now has ${next.proxies.length} proxies.`);
    });

  const doCheck = () =>
    (async () => {
      setChecking(true);
      setError(null);
      setNotice("Testing all proxies…");
      try {
        const next = await proxyService.checkAll();
        setState(next);
        setError(null);
        const reachable = next.proxies.filter((entry) => entry.health?.ok).length;
        setNotice(`Proxy test complete: ${reachable}/${next.proxies.length} reachable.`);
      } catch (e) {
        setNotice(null);
        setError(String(e));
      } finally {
        setChecking(false);
      }
    })();

  const toggle = (id: string, enabled: boolean) =>
    run(async () => {
      let next = await proxyService.setEnabled(id, enabled);
      let modeChange = "";
      if (!enabled && next.mode === "manual" && next.manualId === id) {
        const fallback = next.proxies.find((entry) => entry.enabled);
        next = await proxyService.setMode(fallback ? "manual" : "off", fallback?.id);
        modeChange = fallback
          ? ` Manual mode switched to ${maskProxyUrl(fallback.url)}.`
          : " No enabled proxies remain, so mode was switched off.";
      }
      setState(next);
      await applyAndRestart(`Proxy ${enabled ? "enabled" : "disabled"}.${modeChange}`);
    });

  const remove = (id: string, url: string) => {
    if (!window.confirm(`Remove proxy ${maskProxyUrl(url)}?`)) return;
    return run(async () => {
      let next = await proxyService.remove(id);
      let modeChange = "";
      if (state?.mode === "manual" && state.manualId === id) {
        const fallback = next.proxies.find((entry) => entry.enabled);
        next = await proxyService.setMode(fallback ? "manual" : "off", fallback?.id);
        modeChange = fallback
          ? ` Manual mode switched to ${maskProxyUrl(fallback.url)}.`
          : " No enabled proxies remain, so mode was switched off.";
      }
      setState(next);
      await applyAndRestart(`Proxy removed.${modeChange}`);
    });
  };

  const importCount = importText
    .split(/\r?\n/)
    .filter((line) => line.trim() && !line.trim().startsWith("#")).length;
  const total = state?.proxies.length ?? 0;
  const enabledCount = state?.proxies.filter((entry) => entry.enabled).length ?? 0;
  const eligibleCount = state?.proxies.filter(
    (entry) => entry.enabled && entry.health?.ok !== false,
  ).length ?? 0;
  const passedCount = state?.proxies.filter((entry) => entry.health?.ok === true).length ?? 0;
  const failedCount = state?.proxies.filter((entry) => entry.health?.ok === false).length ?? 0;
  const untestedCount = total - passedCount - failedCount;
  const activeManualProxy =
    state?.mode === "manual"
      ? state.proxies.find((entry) => entry.id === state.manualId && entry.enabled)
      : undefined;
  const manualProxyAvailable = Boolean(activeManualProxy);
  const routeProxyState = state?.mode === "off"
    ? "idle"
    : state?.mode === "manual"
      ? activeManualProxy
        ? activeManualProxy.health?.ok === false
          ? "warning"
          : activeManualProxy.health?.ok === true
            ? "active"
            : "configured"
        : "warning"
      : eligibleCount > 0
        ? "configured"
        : "warning";
  const routeProxyLabel = state?.mode === "off"
    ? "Direct connection"
    : state?.mode === "manual"
      ? activeManualProxy ? maskProxyUrl(activeManualProxy.url) : "Direct fallback"
      : eligibleCount > 0
        ? "Automatic pool"
        : "Direct fallback";
  const routeSourceState = state?.mode === "off"
    ? "direct"
    : state?.mode === "manual"
      ? activeManualProxy?.health?.ok === true
        ? "confirmed"
        : activeManualProxy?.health?.ok === false || !activeManualProxy
          ? "warning"
          : "configured"
      : eligibleCount > 0 ? "configured" : "warning";
  const routeServerState = status?.healthy ? "confirmed" : status?.running ? "warning" : "idle";
  const manualCandidate =
    state?.proxies.find((entry) => entry.id === state.manualId && entry.enabled) ??
    state?.proxies.find((entry) => entry.enabled);

  return (
    <section aria-busy={busy || checking || loading} className="page-stack page-stack--proxy">
      <header className="page-heading">
        <div className="page-heading__copy">
          <h1 className="page-title">Proxies</h1>
          <p className="page-description">
            Free-tier limits are counted per IP. A proxy pool gives every account its own sticky
            IP; opencode honours <span className="font-mono text-xs">HTTPS_PROXY</span> with{" "}
            <span className="font-mono text-xs">NO_PROXY=localhost</span> pinned by this app.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button size="sm" variant="outline" aria-busy={loading} disabled={loading || busy || checking} onClick={() => void load()}>
            <RefreshCw aria-hidden="true" className={cn("size-3.5", loading && "animate-spin")} />
            {loading ? "Reloading…" : "Reload"}
          </Button>
          <Button size="sm" variant="outline" aria-busy={checking} disabled={checking || loading || busy || total === 0} onClick={() => void doCheck()}>
            <Activity aria-hidden="true" className={cn("size-3.5", checking && "animate-pulse")} />
            {checking ? "Checking…" : "Test all"}
          </Button>
        </div>
      </header>

      <section className="proxy-mode-panel" aria-labelledby="proxy-mode-heading">
        <h2 id="proxy-mode-heading" className="proxy-section-title">Routing mode</h2>
        <div role="group" aria-label="Proxy mode" className="mode-selector">
          {modes.map((mode) => (
            <button
              key={mode.id}
              type="button"
              aria-pressed={state?.mode === mode.id}
              disabled={busy || checking || loading || state === null || (mode.id === "manual" && enabledCount === 0)}
              onClick={() => {
                if (mode.id === "manual") {
                  if (manualCandidate) void setMode("manual", manualCandidate.id);
                } else {
                  void setMode(mode.id);
                }
              }}
              className={cn(
                "mode-option focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
                state?.mode === mode.id && "mode-option--selected",
                (busy || checking || loading || state === null || (mode.id === "manual" && enabledCount === 0)) && "opacity-50",
              )}
            >
              {mode.label}
            </button>
          ))}
        </div>
        <p className="proxy-mode-panel__summary">
          {state
            ? modes.find((mode) => mode.id === state.mode)?.hint
            : loading ? "Loading proxy settings…" : "Proxy settings unavailable"}
          {state && total > 0
            ? ` · ${passedCount} passed · ${failedCount} failed · ${untestedCount} not tested`
            : ""}
        </p>
      </section>

      {state && (
        <section className="switchyard-panel route-panel" aria-labelledby="request-route-heading">
          <div className="route-panel__heading">
            <div>
              <h2 id="request-route-heading" className="route-panel__title">Request route</h2>
              <p className="route-panel__copy">Proxy settings apply when opencode serve starts or restarts.</p>
            </div>
            <span className="route-mode">{modes.find((mode) => mode.id === state.mode)?.label}</span>
          </div>
          <div
            className="route-flow"
            data-mode={state.mode}
            role="group"
            aria-label="Configured request path from Console account through proxy or direct connection to local service"
          >
            <div className="route-node" data-state="configured">
              <span className="route-node__marker"><KeyRound aria-hidden="true" className="size-4" /></span>
              <div className="route-node__content">
                <div className="route-node__name">Console request</div>
                <div className="route-node__detail">
                  {state.mode === "auto" ? "Account-specific sticky assignment" : state.mode === "manual" ? "Shared route for Console accounts" : "Direct connection"}
                </div>
              </div>
            </div>
            <span aria-hidden="true" className="route-connector" data-state={routeSourceState} />
            <div className="route-node" data-state={routeProxyState}>
              <span className="route-node__marker"><Waypoints aria-hidden="true" className="size-4" /></span>
              <div className="route-node__content">
                <div className="route-node__name">{routeProxyLabel}</div>
                <div className="route-node__detail">
                  {state.mode === "auto"
                    ? eligibleCount > 0
                      ? `${eligibleCount} eligible · ${Object.keys(state.bindings ?? {}).length} saved bindings`
                      : "No eligible proxy; requests fall back to direct"
                    : state.mode === "manual"
                      ? activeManualProxy
                        ? activeManualProxy.health?.ok === true
                          ? `Selected · last test passed${activeManualProxy.health.latencyMs === undefined ? "" : ` · ${activeManualProxy.health.latencyMs} ms`}`
                          : activeManualProxy.health?.ok === false
                            ? "Selected · last test failed"
                            : "Selected · not tested"
                        : "No enabled manual selection; direct fallback"
                      : "Proxy mode is off"}
                </div>
              </div>
            </div>
            <span aria-hidden="true" className="route-connector" data-state={routeServerState} />
            <div className="route-node" data-state={status?.healthy ? "active" : status?.running ? "warning" : "idle"}>
              <span className="route-node__marker"><Server aria-hidden="true" className="size-4" /></span>
              <div className="route-node__content">
                <div className="route-node__name">opencode serve</div>
                <div className="route-node__detail">
                  {status?.healthy
                    ? `Healthy · :${status.port}`
                    : status?.running
                      ? "Running · not healthy"
                      : status
                        ? "Stopped · applies on next start"
                        : "Status unavailable"}
                </div>
              </div>
            </div>
          </div>
          <p className="route-panel__copy">
            {state.mode === "auto"
              ? "Auto reuses an account’s enabled proxy unless a health test failed; otherwise it assigns an unbound enabled proxy that has not failed a test, falling back to the first eligible proxy."
              : state.mode === "manual"
                ? "Manual mode uses the selected enabled proxy for every account, regardless of its last health test."
                : "Off mode connects directly without using the proxy pool."}
          </p>
        </section>
      )}

      <div className="proxy-feedback">
        {state?.mode === "auto" && eligibleCount === 0 && (
          <div role="status" className="status-message status-message--warning">
            Auto mode has no eligible proxies. Requests will connect directly; enable a proxy or retest the pool to retry failed entries.
          </div>
        )}
        {state?.mode === "manual" && !manualProxyAvailable && (
          <div role="status" className="status-message status-message--warning">
            The selected manual proxy is unavailable. opencode will connect directly until you choose an enabled proxy.
          </div>
        )}
        {notice && (
          <div role="status" aria-live="polite" className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">{notice}</div>
        )}
        {error && (
          <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            <span>{error}</span>
            {state === null && !loading && (
              <Button size="sm" variant="outline" onClick={() => void load()}>
                Try again
              </Button>
            )}
          </div>
        )}
      </div>

      <section className="proxy-import" aria-labelledby="proxy-import-heading">
        <h2 id="proxy-import-heading" className="proxy-section-title">Import proxies</h2>
        <p id="proxy-import-help" className="proxy-import__help">
          One per line — <span className="font-mono">http://host:port</span>,{" "}
          <span className="font-mono">socks5://user:pass@host:port</span> or bare{" "}
          <span className="font-mono">host:port</span>. Lines starting with # are ignored.
        </p>
        <label htmlFor="proxy-import-input" className="sr-only">Proxy addresses, one per line</label>
        <textarea
          id="proxy-import-input"
          aria-describedby="proxy-import-help"
          value={importText}
          onChange={(event) => setImportText(event.target.value)}
          rows={4}
          spellCheck={false}
          placeholder={"1.2.3.4:8080\nhttp://user:pass@5.6.7.8:3128"}
          className="proxy-import__input"
        />
        <div className="proxy-import__footer">
          <span aria-live="polite" className="text-xs text-muted-foreground">
            {importCount} {importCount === 1 ? "proxy" : "proxies"} to import
          </span>
          <Button size="sm" disabled={busy || checking || loading || importCount === 0} onClick={() => void doImport()}>
            <Plus aria-hidden="true" className="size-3.5" /> Import
          </Button>
        </div>
      </section>


      <section className="proxy-pool-section" aria-labelledby="proxy-pool-heading">
        <header className="proxy-pool-section__header">
          <div>
            <h2 id="proxy-pool-heading" className="proxy-section-title">Proxy pool</h2>
            <p role="status" aria-live="polite" className="proxy-pool-section__summary">
              {state === null
                ? loading ? "Loading pool…" : "Pool unavailable"
                : `${total} total · ${enabledCount} enabled`}
            </p>
          </div>
        </header>
        {state?.proxies.length === 0 && (
          <p role="status" className="proxy-pool-empty">
            No proxies yet. Import a pool, test it, then select Auto or Manual routing.
          </p>
        )}
        {state && state.proxies.length > 0 && (
          <ul className="proxy-pool divide-y divide-border">
            {state.proxies.map((entry) => {
              const selected = state.mode === "manual" && state.manualId === entry.id;
              return (
                <li key={entry.id} className="proxy-row" data-selected={selected}>
                  <Switch
                    aria-label={`Enable proxy ${maskProxyUrl(entry.url)}`}
                    checked={entry.enabled}
                    disabled={busy || checking || loading}
                    onCheckedChange={(value) => void toggle(entry.id, value)}
                  />
                  <div className="proxy-row__details min-w-0 flex-1">
                    <div className="truncate font-mono text-xs">{maskProxyUrl(entry.url)}</div>
                    <div className="text-xs text-muted-foreground">
                      {entry.health
                        ? entry.health.ok
                          ? `last test passed · ${entry.health.latencyMs ?? "?"} ms`
                          : `last test failed · ${entry.health.error ?? "unreachable"}`
                        : "not tested"}
                      {state.bindings && Object.values(state.bindings).includes(entry.id)
                        ? " · bound to an account"
                        : ""}
                    </div>
                  </div>
                  <span
                    className="proxy-row__health"
                    data-state={entry.health ? (entry.health.ok ? "tested" : "failed") : "untested"}
                  >
                    {entry.health ? (entry.health.ok ? "OK" : "FAIL") : "?"}
                  </span>
                  <div className="proxy-row__actions">
                    <Button
                      size="sm"
                      variant={selected ? "secondary" : "outline"}
                      aria-pressed={selected}
                      disabled={busy || checking || loading || !entry.enabled || selected}
                      onClick={() => void setManual(entry.id)}
                    >
                      {selected ? "Active" : "Use"}
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      aria-label={`Remove proxy ${maskProxyUrl(entry.url)}`}
                      title="Remove proxy"
                      disabled={busy || checking || loading}
                      onClick={() => void remove(entry.id, entry.url)}
                    >
                      <Trash2 aria-hidden="true" className="size-3.5" />
                    </Button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </section>
  );
}
