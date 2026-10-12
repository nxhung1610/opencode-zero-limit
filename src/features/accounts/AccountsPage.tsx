import { useCallback, useEffect, useState } from "react";
import { Check, ExternalLink, KeyRound, LogOut, Plus, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  consoleService,
  type ConsoleConnection,
  type ConsoleLoginAttempt,
} from "@/services/console";
import type { OpencodeStatus } from "@/services/opencode";
import { SetupGuide } from "@/features/accounts/SetupGuide";

interface AccountsPageProps {
  status: OpencodeStatus | null;
  statusLoading: boolean;
  onStatus: (status: OpencodeStatus) => void;
  onGoToUsage: () => void;
  onGoToProxies: () => void;
  onGoToSettings: () => void;
}

type AccountState = "loading" | "error" | "empty" | "ready";

function versionMajor(version: string | null | undefined): number | null {
  const match = version?.match(/(?:^|\D)(\d+)\.\d+\.\d+/);
  return match ? Number(match[1]) : null;
}

export function AccountsPage({
  status,
  statusLoading,
  onStatus,
  onGoToUsage,
  onGoToProxies,
  onGoToSettings,
}: AccountsPageProps) {
  const [connections, setConnections] = useState<ConsoleConnection[] | null>(null);
  const [loginAttempt, setLoginAttempt] = useState<ConsoleLoginAttempt | null>(null);
  const [loginCode, setLoginCode] = useState("");
  const [selectedConnectionID, setSelectedConnectionID] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(false);

  const serverReady = Boolean(status?.healthy);
  const v2Available = versionMajor(status?.version) === 2;

  const load = useCallback(async () => {
    if (!serverReady || !v2Available) {
      setConnections(null);
      setLoadError(null);
      setLoading(false);
      return;
    }
    setLoading(true);
    setLoadError(null);
    try {
      const saved = await consoleService.connections();
      setConnections(saved);
      setLoadError(null);
    } catch (e) {
      setConnections(null);
      setLoadError(String(e));
    } finally {
      setLoading(false);
    }
  }, [serverReady, v2Available]);

  useEffect(() => {
    void load();
  }, [load]);

  const activeConnection = connections?.find((connection) => connection.active) ?? null;
  const selectedConnection = connections?.find((connection) => connection.id === selectedConnectionID)
    ?? activeConnection
    ?? connections?.[0]
    ?? null;
  const accountState: AccountState = statusLoading || loading || (serverReady && v2Available && connections === null && !loadError)
    ? "loading"
    : !v2Available || loadError
      ? "error"
      : connections?.length
        ? "ready"
        : "empty";

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

  const addAccount = () => run(async () => {
    const attempt = await consoleService.loginStart();
    setLoginAttempt(attempt);
    setLoginCode("");
    setNotice("Sign-in link ready. Complete authorization in your browser; OpenCode saves the credential locally.");
  });

  const cancelLogin = () => {
    if (!loginAttempt) return;
    void run(async () => {
      await consoleService.loginCancel(loginAttempt.attemptID);
      setLoginAttempt(null);
      setLoginCode("");
      setNotice("Sign-in cancelled.");
    });
  };

  const completeCodeLogin = () => {
    if (!loginAttempt || !loginCode.trim()) return;
    void run(async () => {
      await consoleService.loginComplete(loginAttempt.attemptID, loginCode.trim());
      setNotice("Code submitted. Waiting for OpenCode to save the Console credential locally…");
    });
  };

  const useConnection = (connection: ConsoleConnection) => {
    setSelectedConnectionID(connection.id);
    if (connection.active) return;
    void run(async () => {
      setNotice(`Activating ${connection.label}…`);
      onStatus(await consoleService.activate(connection.id));
      await load();
      setNotice(`${connection.label} is now the active OpenCode Console account.`);
    });
  };

  const removeConnection = (connection: ConsoleConnection) => {
    if (!window.confirm(`Remove the locally saved OpenCode Console credential “${connection.label}”?`)) return;
    void run(async () => {
      setNotice(`Removing ${connection.label}…`);
      const message = await consoleService.logout(connection.id);
      if (selectedConnectionID === connection.id) setSelectedConnectionID(null);
      await load();
      setNotice(message);
    });
  };

  useEffect(() => {
    if (!loginAttempt || !serverReady || !v2Available) return;
    let disposed = false;
    let timer: number | undefined;

    const poll = async () => {
      try {
        const result = await consoleService.loginStatus(loginAttempt.attemptID);
        if (disposed) return;
        if (result.status === "complete") {
          setLoginAttempt(null);
          setLoginCode("");
          setNotice("OpenCode Console connected. The credential is saved in the local OpenCode database.");
          await load();
          return;
        }
        if (result.status === "expired" || result.status === "failed") {
          setLoginAttempt(null);
          setLoginCode("");
          setError(result.message);
          return;
        }
      } catch (e) {
        if (!disposed) setError(`Could not check sign-in status: ${String(e)}`);
      }
      if (!disposed) timer = window.setTimeout(() => void poll(), 1_500);
    };

    timer = window.setTimeout(() => void poll(), 1_000);
    return () => {
      disposed = true;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  }, [loginAttempt, serverReady, v2Available, load]);

  return (
    <section aria-busy={busy || loading || statusLoading} className="page-stack">
      <header className="page-heading">
        <div className="page-heading__copy">
          <h1 className="page-title">Accounts</h1>
          <p className="page-description">
            OpenCode Console connections are authorized in your browser and stored by the local OpenCode service.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button size="sm" variant="outline" disabled={busy || loading || !serverReady || !v2Available} onClick={() => void load()}>
            <RotateCw aria-hidden="true" className="size-3.5" /> {loading ? "Reloading…" : "Reload"}
          </Button>
          <Button size="sm" disabled={busy || Boolean(loginAttempt) || !serverReady || !v2Available} onClick={() => void addAccount()}>
            <Plus aria-hidden="true" className="size-3.5" /> Add account
          </Button>
        </div>
      </header>

      <SetupGuide
        serverReady={serverReady}
        statusLoading={statusLoading}
        accountState={accountState}
        hasActiveAccount={Boolean(activeConnection)}
        onGoToUsage={onGoToUsage}
        onGoToProxies={onGoToProxies}
        onGoToSettings={onGoToSettings}
      />

      {notice && (
        <div role="status" aria-live="polite" className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">
          {notice}
        </div>
      )}
      {error && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      {loginAttempt && (
        <section className="switchyard-panel grid gap-3 p-4" aria-labelledby="console-login-heading">
          <div>
            <h2 id="console-login-heading" className="text-sm font-semibold">Finish browser sign-in</h2>
            <p className="mt-1 text-xs text-muted-foreground">{loginAttempt.instructions}</p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <a
              className="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:opacity-90"
              href={loginAttempt.url}
              target="_blank"
              rel="noopener noreferrer"
            >
              <ExternalLink aria-hidden="true" className="size-3.5" /> Open sign-in in browser
            </a>
            <Button size="sm" variant="ghost" disabled={busy} onClick={cancelLogin}>Cancel</Button>
            <span role="status" aria-live="polite" className="text-xs text-muted-foreground">Waiting for authorization…</span>
          </div>
          {loginAttempt.mode === "code" && (
            <div className="grid max-w-lg gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
              <label className="grid gap-1 text-xs font-medium" htmlFor="console-login-code">
                Authorization code
                <input
                  id="console-login-code"
                  autoComplete="one-time-code"
                  value={loginCode}
                  onChange={(event) => setLoginCode(event.target.value)}
                  className="h-9 rounded-md border border-input bg-background px-3 text-sm font-normal outline-none focus-visible:ring-2 focus-visible:ring-ring"
                />
              </label>
              <Button size="sm" disabled={busy || !loginCode.trim()} onClick={completeCodeLogin}>Submit code</Button>
            </div>
          )}
        </section>
      )}

      {statusLoading ? (
        <div role="status" aria-live="polite" className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          Checking opencode serve…
        </div>
      ) : !serverReady ? (
        <div role="status" className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          Local accounts are available after opencode serve is running.
        </div>
      ) : !v2Available ? (
        <div role="status" className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          Browser-based account connections require OpenCode CLI v2. The detected version is {status?.version ?? "unknown"}.
        </div>
      ) : loading || (connections === null && !loadError) ? (
        <div role="status" aria-live="polite" className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          Loading saved Console connections…
        </div>
      ) : loadError ? (
        <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-sm text-destructive">
          <span>Could not load Console connections: {loadError}</span>
          <Button size="sm" variant="outline" disabled={loading} onClick={() => void load()}>
            Try again
          </Button>
        </div>
      ) : connections?.length === 0 ? (
        <div className="switchyard-panel p-6 text-sm text-muted-foreground">
          No OpenCode Console accounts are connected yet. Use <span className="font-medium text-foreground">Add account</span> to generate a browser sign-in link.
        </div>
      ) : connections && (
        <>
          <section className="account-current" aria-labelledby="account-current-heading">
            <div className="account-current__copy">
              <h2 id="account-current-heading" className="account-current__label">Active Console account</h2>
              {activeConnection ? (
                <>
                  <div className="account-current__name">{activeConnection.label}</div>
                  <div className="account-current__detail">OpenCode Console <span aria-hidden="true">·</span> OAuth connection saved locally</div>
                </>
              ) : (
                <div className="account-current__detail">No active Console account. Select a saved connection below.</div>
              )}
            </div>
            {activeConnection && (
              <span className="account-current__state">
                <Check aria-hidden="true" className="size-3.5" /> Active
              </span>
            )}
          </section>

          <div className="account-workspace">
            <section className="account-panel account-directory" aria-labelledby="account-directory-heading">
              <header className="account-panel__header">
                <div>
                  <h2 id="account-directory-heading" className="account-panel__title">Saved Console accounts</h2>
                  <p className="account-panel__subtitle">{connections.length} {connections.length === 1 ? "connection" : "connections"} stored locally</p>
                </div>
              </header>
              <ul className="account-picker">
                {connections.map((connection) => {
                  const isSelected = selectedConnection?.id === connection.id;
                  return (
                    <li key={connection.id} className="account-picker__item" data-selected={isSelected}>
                      <button
                        type="button"
                        aria-pressed={isSelected}
                        onClick={() => setSelectedConnectionID(connection.id)}
                        className="account-picker__select"
                      >
                        <KeyRound aria-hidden="true" className="account-picker__icon size-4" />
                        <span className="account-picker__copy">
                          <span className="account-picker__email">{connection.label}</span>
                          <span className="account-picker__host">OpenCode Console · OAuth</span>
                        </span>
                      </button>
                      <div className="account-picker__meta">
                        {connection.active && <span className="account-picker__active">Active</span>}
                        <Button
                          size="sm"
                          variant="ghost"
                          aria-label={`Remove ${connection.label}`}
                          title={`Remove ${connection.label}`}
                          disabled={busy}
                          onClick={() => removeConnection(connection)}
                        >
                          <LogOut aria-hidden="true" className="size-3.5" />
                        </Button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </section>

            <section className="account-panel account-organizations" aria-labelledby="connection-details-heading">
              <header className="account-panel__header">
                <div className="min-w-0">
                  <h2 id="connection-details-heading" className="account-panel__title">Connection details</h2>
                  <p className="account-panel__subtitle truncate">{selectedConnection?.label ?? "Choose a saved account"}</p>
                </div>
              </header>
              {selectedConnection ? (
                <div className="grid gap-3 p-4">
                  <div className="account-org" data-active={selectedConnection.active}>
                    <span className="account-org__identity">
                      <span aria-hidden="true" data-active={selectedConnection.active} className="account-org__indicator size-2" />
                      <span className="account-org__copy">
                        <span className="account-org__name">{selectedConnection.label}</span>
                        <span className="account-org__id">OpenCode Console · OAuth</span>
                      </span>
                    </span>
                    <span className="account-organizations__count">{selectedConnection.active ? "Active" : "Saved"}</span>
                  </div>
                  <p className="px-1 text-xs leading-relaxed text-muted-foreground">
                    OpenCode manages this credential in its local database. RelayDock does not read or expose the credential value.
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Button size="sm" variant={selectedConnection.active ? "secondary" : "outline"} disabled={busy || selectedConnection.active} onClick={() => useConnection(selectedConnection)}>
                      {selectedConnection.active ? "Active account" : "Use account"}
                    </Button>
                    <Button size="sm" variant="ghost" disabled={busy} onClick={() => removeConnection(selectedConnection)}>
                      <LogOut aria-hidden="true" className="size-3.5" /> Remove account
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="account-organizations__empty">Select a saved Console account to review its local connection.</div>
              )}
            </section>
          </div>
        </>
      )}
    </section>
  );
}
