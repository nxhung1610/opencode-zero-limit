import { useCallback, useEffect, useState } from "react";
import { listenQuota } from "@/services/bridge";
import { Circle, Monitor, Moon, Play, RefreshCw, Square, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Sidebar, type PageId } from "@/components/layout/Sidebar";
import { AccountsPage } from "@/features/accounts/AccountsPage";
import { UsagePage } from "@/features/usage/UsagePage";
import { ProxyPage } from "@/features/proxy/ProxyPage";
import { SettingsPage } from "@/features/settings/SettingsPage";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";
import { settingsService } from "@/services/settings";
import { applyTheme, watchSystemTheme } from "@/lib/theme";
import type { QuotaEvent } from "@/services/quota";

function StatusDot({
  status,
  checking,
  error,
}: {
  status: OpencodeStatus | null;
  checking: boolean;
  error: string | null;
}) {
  const state = !status
    ? error
      ? "unavailable"
      : "checking"
    : !status.running
      ? "stopped"
      : status.healthy
        ? "healthy"
        : "unhealthy";
  const label = !status
    ? checking
      ? "checking…"
      : error
        ? "unavailable"
        : "checking…"
    : !status.running
      ? "stopped"
      : status.healthy
        ? `healthy :${status.port}`
        : "unhealthy";
  return (
    <span role="status" aria-live="polite" className="server-health">
      <Circle aria-hidden="true" data-state={state} className="server-health__dot size-2 fill-current" />
      <span>opencode serve</span>
      <span aria-hidden="true" className="server-health__separator">·</span>
      <span className="server-health__state">{label}</span>
    </span>
  );
}

function App() {
  const [page, setPage] = useState<PageId>("accounts");
  const [status, setStatus] = useState<OpencodeStatus | null>(null);
  const [statusLoading, setStatusLoading] = useState(true);
  const [statusError, setStatusError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [serverAction, setServerAction] = useState<"start" | "stop" | null>(null);
  const [quota, setQuota] = useState<QuotaEvent | null>(null);

  const refresh = useCallback(async () => {
    try {
      setStatus(await opencodeService.status());
      setStatusError(null);
    } catch (error) {
      setStatusError(String(error));
      console.error("opencode_status failed", error);
    } finally {
      setStatusLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void listenQuota(setQuota)
      .then((stop) => {
        if (cancelled) stop();
        else unlisten = stop;
      })
      .catch((error) => console.error("quota listener failed", error));
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  const [theme, setTheme] = useState<string>("dark");

  useEffect(() => {
    void settingsService
      .get()
      .then((settings) => setTheme(settings.theme ?? "system"))
      .catch(() => {});
  }, []);

  useEffect(() => {
    applyTheme(theme);
    return watchSystemTheme(() => theme);
  }, [theme]);

  async function cycleTheme() {
    const previous = theme;
    const next = theme === "light" ? "dark" : theme === "dark" ? "system" : "light";
    setTheme(next);
    setActionError(null);
    try {
      const current = await settingsService.get();
      await settingsService.set({ ...current, theme: next });
    } catch (error) {
      setTheme(previous);
      setActionError(`Could not save theme: ${String(error)}`);
      console.error("failed to save theme", error);
    }
  }

  async function toggleServer() {
    const action = status?.running ? "stop" : "start";
    setServerAction(action);
    setActionError(null);
    try {
      setStatus(
        action === "stop" ? await opencodeService.stop() : await opencodeService.start(),
      );
      setStatusError(null);
    } catch (error) {
      setActionError(`Could not ${action} opencode serve: ${String(error)}`);
      console.error("opencode server toggle failed", error);
    } finally {
      setServerAction(null);
    }
  }

  const visibleError = actionError ?? statusError ?? status?.error;

  return (
    <div className="app-shell flex h-screen overflow-hidden bg-background text-foreground">
      <Sidebar active={page} onSelect={setPage} />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="app-topbar">
          <div className="app-topbar__left">
            <div className="app-topbar__signals">
              <StatusDot status={status} checking={statusLoading} error={statusError} />
              {quota && Date.now() - quota.at < 60 * 60 * 1000 && (
                <span role="status" className="quota-signal">
                  <Circle aria-hidden="true" className="size-2 fill-current" /> quota limit hit
                  {quota.rotatedTo ? " · rotated" : ""}
                </span>
              )}
            </div>
          </div>
          <div className="app-topbar__actions">
            <Button
              size="icon-sm"
              variant="ghost"
              disabled={statusLoading}
              onClick={() => void refresh()}
              title="Refresh opencode status"
              aria-label="Refresh opencode status"
            >
              <RefreshCw aria-hidden="true" className={statusLoading ? "animate-spin" : ""} />
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => void cycleTheme()}
              title={`Theme: ${theme}`}
              aria-label={`Theme is ${theme}; click to cycle theme`}
            >
              {theme === "dark" ? (
                <Moon aria-hidden="true" className="size-3.5" />
              ) : theme === "light" ? (
                <Sun aria-hidden="true" className="size-3.5" />
              ) : (
                <Monitor aria-hidden="true" className="size-3.5" />
              )}
              <span className="ml-1 capitalize">{theme}</span>
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={statusLoading || serverAction !== null}
              aria-busy={serverAction !== null}
              onClick={() => void toggleServer()}
            >
              {serverAction === "start" ? (
                <>
                  <Play aria-hidden="true" className="size-3.5" /> Starting…
                </>
              ) : serverAction === "stop" ? (
                <>
                  <Square aria-hidden="true" className="size-3.5" /> Stopping…
                </>
              ) : status?.running ? (
                <>
                  <Square aria-hidden="true" className="size-3.5" /> Stop
                </>
              ) : (
                <>
                  <Play aria-hidden="true" className="size-3.5" /> Start
                </>
              )}
            </Button>
          </div>
        </header>
        {visibleError && (
          <div
            role="alert"
            className="app-error border-b border-destructive/30 px-4 py-2 text-xs text-destructive md:px-6"
          >
            {visibleError}
          </div>
        )}
        <main className="app-main flex-1 overflow-auto px-5 py-6 md:px-8 md:py-7">
          <div className="w-full">
            {page === "accounts" && (
              <AccountsPage
                status={status}
                statusLoading={statusLoading}
                onStatus={setStatus}
                onGoToUsage={() => setPage("usage")}
                onGoToProxies={() => setPage("proxy")}
                onGoToSettings={() => setPage("settings")}
              />
            )}
            {page === "usage" && <UsagePage quota={quota} />}
            {page === "proxy" && <ProxyPage status={status} onStatus={setStatus} />}
            {page === "settings" && (
              <SettingsPage onStatus={setStatus} onGoToUsage={() => setPage("usage")} />
            )}
          </div>
        </main>
      </div>
    </div>
  );
}

export default App;
