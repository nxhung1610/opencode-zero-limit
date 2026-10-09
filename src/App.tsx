import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { Circle, Play, Square } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Sidebar, type PageId } from "@/components/layout/Sidebar";
import { AccountsPage } from "@/features/accounts/AccountsPage";
import { UsagePage } from "@/features/usage/UsagePage";
import { ProxyPage } from "@/features/proxy/ProxyPage";
import { SettingsPage } from "@/features/settings/SettingsPage";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";
import type { QuotaEvent } from "@/services/quota";

function StatusDot({ status }: { status: OpencodeStatus | null }) {
  const tone = !status?.running
    ? "bg-muted-foreground"
    : status.healthy
      ? "bg-emerald-500"
      : "bg-amber-500";
  const label = !status?.running
    ? "stopped"
    : status.healthy
      ? `healthy :${status.port}`
      : "unhealthy";
  return (
    <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
      <Circle className={`size-2 fill-current ${tone}`} /> opencode serve: {label}
    </span>
  );
}

function App() {
  const [page, setPage] = useState<PageId>("accounts");
  const [status, setStatus] = useState<OpencodeStatus | null>(null);
  const [quota, setQuota] = useState<QuotaEvent | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await opencodeService.status());
    } catch (error) {
      console.error("opencode_status failed", error);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    const unlisten = listen<QuotaEvent>("quota", (event) => setQuota(event.payload));
    return () => {
      void unlisten.then((fn) => fn());
    };
  }, []);

  async function toggleServer() {
    setBusy(true);
    try {
      setStatus(status?.running ? await opencodeService.stop() : await opencodeService.start());
    } catch (error) {
      console.error("opencode server toggle failed", error);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex h-screen overflow-hidden bg-background text-foreground">
      <Sidebar active={page} onSelect={setPage} />
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-between gap-3 border-b border-border px-6 py-3">
          <div className="flex items-center gap-4">
            <StatusDot status={status} />
            {quota && Date.now() - quota.at < 60 * 60 * 1000 && (
              <span className="flex items-center gap-1.5 text-xs text-amber-600">
                <Circle className="size-2 fill-current" /> quota limit hit
                {quota.rotatedTo ? ` · rotated` : ""}
              </span>
            )}
          </div>
          <div className="flex items-center gap-2">
            {status?.error && (
              <span className="max-w-md truncate text-xs text-destructive">{status.error}</span>
            )}
            <Button size="sm" variant="outline" disabled={busy} onClick={() => void toggleServer()}>
              {status?.running ? (
                <>
                  <Square className="size-3.5" /> Stop
                </>
              ) : (
                <>
                  <Play className="size-3.5" /> Start
                </>
              )}
            </Button>
          </div>
        </header>
        <main className="flex-1 overflow-auto px-6 py-5">
          {page === "accounts" && <AccountsPage status={status} onStatus={setStatus} />}
          {page === "usage" && <UsagePage quota={quota} />}
          {page === "proxy" && <ProxyPage onStatus={setStatus} />}
          {page === "settings" && <SettingsPage onStatus={setStatus} />}
        </main>
      </div>
    </div>
  );
}

export default App;
