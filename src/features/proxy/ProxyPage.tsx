import { useCallback, useEffect, useState } from "react";
import { Activity, Plus, Trash2, Waypoints } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { cn } from "cn";
import { maskProxyUrl, proxyService, type ProxyMode, type ProxyState } from "@/services/proxy";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";

interface ProxyPageProps {
  onStatus: (status: OpencodeStatus) => void;
}

const modes: { id: ProxyMode; label: string; hint: string }[] = [
  { id: "off", label: "Off", hint: "Direct connection" },
  { id: "auto", label: "Auto", hint: "Sticky per account, round-robin on failure" },
  { id: "manual", label: "Manual", hint: "One fixed proxy" },
];

export function ProxyPage({ onStatus }: ProxyPageProps) {
  const [state, setState] = useState<ProxyState | null>(null);
  const [importText, setImportText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [checking, setChecking] = useState(false);

  const load = useCallback(async () => {
    try {
      setState(await proxyService.list());
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  /** Proxy env only applies to a freshly spawned serve. */
  async function applyAndRestart() {
    onStatus(await opencodeService.restart());
    setNotice("opencode serve restarted with the new proxy settings");
  }

  async function run(action: () => Promise<void>) {
    setBusy(true);
    try {
      await action();
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  const setMode = (mode: ProxyMode, manualId?: string) =>
    run(async () => {
      setState(await proxyService.setMode(mode, manualId));
      if (mode === "off") {
        setNotice("Proxy disabled");
        return;
      }
      await applyAndRestart();
    });

  const setManual = (id: string) => setMode("manual", id);

  const doImport = () =>
    run(async () => {
      const next = await proxyService.import(importText);
      setState(next);
      setImportText("");
      setNotice(`Imported — pool now has ${next.proxies.length} proxies`);
    });

  const doCheck = () =>
    (async () => {
      setChecking(true);
      try {
        setState(await proxyService.checkAll());
        setError(null);
      } catch (e) {
        setError(String(e));
      } finally {
        setChecking(false);
      }
    })();

  const toggle = (id: string, enabled: boolean) =>
    run(async () => {
      setState(await proxyService.setEnabled(id, enabled));
    });

  const remove = (id: string) =>
    run(async () => {
      setState(await proxyService.remove(id));
      setNotice("Proxy removed");
    });

  const total = state?.proxies.length ?? 0;
  const alive =
    state?.proxies.filter((entry) => entry.health?.ok).length ?? 0;

  return (
    <section className="space-y-4">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <h1 className="flex items-center gap-2 text-lg font-semibold">
            <Waypoints className="size-5" /> Proxies
          </h1>
          <p className="text-sm text-muted-foreground">
            Free-tier limits are counted per IP. A proxy pool gives every account its own sticky
            IP; opencode honours <span className="font-mono text-xs">HTTPS_PROXY</span> with{" "}
            <span className="font-mono text-xs">NO_PROXY=localhost</span> pinned by this app.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button size="sm" variant="outline" disabled={checking || total === 0} onClick={() => void doCheck()}>
            <Activity className={cn("size-3.5", checking && "animate-pulse")} />
            {checking ? "Checking…" : "Test all"}
          </Button>
        </div>
      </header>

      <div className="flex flex-wrap items-center gap-3 rounded-lg border border-border px-4 py-3">
        <div className="flex rounded-md border border-border p-0.5">
          {modes.map((mode) => (
            <button
              key={mode.id}
              type="button"
              disabled={busy || (mode.id === "manual" && total === 0)}
              onClick={() => void setMode(mode.id)}
              className={cn(
                "rounded px-3 py-1 text-xs",
                state?.mode === mode.id
                  ? "bg-accent font-medium"
                  : "text-muted-foreground hover:text-foreground",
                (busy || (mode.id === "manual" && total === 0)) && "opacity-50",
              )}
            >
              {mode.label}
            </button>
          ))}
        </div>
        <span className="text-xs text-muted-foreground">
          {modes.find((mode) => mode.id === state?.mode)?.hint}
          {total > 0 ? ` · ${alive}/${total} alive` : ""}
        </span>
      </div>

      <div className="rounded-lg border border-border p-4">
        <div className="mb-2 text-sm font-medium">Import proxies</div>
        <p className="mb-2 text-xs text-muted-foreground">
          One per line — <span className="font-mono">http://host:port</span>,{" "}
          <span className="font-mono">socks5://user:pass@host:port</span> or bare{" "}
          <span className="font-mono">host:port</span>. Lines starting with # are ignored.
        </p>
        <textarea
          value={importText}
          onChange={(event) => setImportText(event.target.value)}
          rows={4}
          spellCheck={false}
          placeholder={"1.2.3.4:8080\nhttp://user:pass@5.6.7.8:3128"}
          className="w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-xs outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
        />
        <div className="mt-2 flex justify-end">
          <Button size="sm" disabled={busy || !importText.trim()} onClick={() => void doImport()}>
            <Plus className="size-3.5" /> Import
          </Button>
        </div>
      </div>

      {notice && (
        <div className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">{notice}</div>
      )}
      {error && (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      {state && state.proxies.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          No proxies yet. Import a pool above, then test it and switch the mode to Auto or Manual.
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {state?.proxies.map((entry) => (
            <li key={entry.id} className="flex items-center gap-3 px-4 py-2.5">
              <Switch
                checked={entry.enabled}
                disabled={busy}
                onCheckedChange={(value) => void toggle(entry.id, value)}
              />
              <div className="min-w-0 flex-1">
                <div className="truncate font-mono text-xs">{maskProxyUrl(entry.url)}</div>
                <div className="text-xs text-muted-foreground">
                  {entry.health
                    ? entry.health.ok
                      ? `alive · ${entry.health.latencyMs ?? "?"} ms`
                      : `dead · ${entry.health.error ?? "unreachable"}`
                    : "not tested"}
                  {state.bindings && Object.values(state.bindings).includes(entry.id)
                    ? " · bound to an account"
                    : ""}
                </div>
              </div>
              <span
                className={cn(
                  "rounded px-1.5 py-0.5 text-[10px]",
                  entry.health
                    ? entry.health.ok
                      ? "bg-emerald-500/15 text-emerald-600"
                      : "bg-destructive/15 text-destructive"
                    : "bg-muted text-muted-foreground",
                )}
              >
                {entry.health ? (entry.health.ok ? "OK" : "FAIL") : "?"}
              </span>
              <Button
                size="sm"
                variant={state.mode === "manual" && state.manualId === entry.id ? "secondary" : "outline"}
                disabled={busy || !entry.enabled}
                onClick={() => void setManual(entry.id)}
              >
                Use
              </Button>
              <Button size="sm" variant="ghost" disabled={busy} onClick={() => void remove(entry.id)}>
                <Trash2 className="size-3.5" />
              </Button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
