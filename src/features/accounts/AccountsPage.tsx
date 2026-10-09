import { useCallback, useEffect, useMemo, useState } from "react";
import { KeyRound, LogOut, Plus, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "cn";
import { consoleService, type ConsoleOrg } from "@/services/console";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";

interface AccountsPageProps {
  status: OpencodeStatus | null;
  onStatus: (status: OpencodeStatus) => void;
}

interface AccountGroup {
  email: string;
  url: string;
  orgs: ConsoleOrg[];
}

export function AccountsPage({ status, onStatus }: AccountsPageProps) {
  const [orgs, setOrgs] = useState<ConsoleOrg[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const serverReady = Boolean(status?.healthy);

  const load = useCallback(async () => {
    if (!serverReady) {
      setOrgs(null);
      return;
    }
    try {
      setOrgs(await consoleService.orgs());
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, [serverReady]);

  useEffect(() => {
    void load();
  }, [load]);

  const groups = useMemo(() => {
    if (!orgs) return [];
    const byKey = new Map<string, AccountGroup>();
    for (const org of orgs) {
      const key = `${org.accountEmail}|${org.accountUrl}`;
      const group = byKey.get(key) ?? {
        email: org.accountEmail,
        url: org.accountUrl,
        orgs: [],
      };
      group.orgs.push(org);
      byKey.set(key, group);
    }
    return [...byKey.values()].sort((a, b) =>
      a.orgs.some((o) => o.active) === b.orgs.some((o) => o.active)
        ? a.email.localeCompare(b.email)
        : a.orgs.some((o) => o.active)
          ? -1
          : 1,
    );
  }, [orgs]);

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

  const startServer = () =>
    run(async () => {
      onStatus(await opencodeService.start());
      setNotice("opencode serve started");
    });

  const switchOrg = (org: ConsoleOrg) =>
    run(async () => {
      setNotice(`Switching to ${org.orgName} (${org.accountEmail})…`);
      onStatus(await consoleService.switch(org.accountID, org.orgID));
      await load();
      setNotice(`Switched to ${org.orgName} — opencode serve restarted`);
    });

  const addAccount = () =>
    run(async () => {
      const message = await consoleService.login();
      setNotice(`${message}. Finish the login, then press Reload.`);
    });

  const logout = (email: string) =>
    run(async () => {
      const message = await consoleService.logout(email);
      await load();
      setNotice(message || `Logged out ${email}`);
    });

  return (
    <section className="space-y-4">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <h1 className="flex items-center gap-2 text-lg font-semibold">
            <KeyRound className="size-5" /> Accounts
          </h1>
          <p className="text-sm text-muted-foreground">
            Console accounts stored by opencode (SQLite). The active account+org decides which
            workspace — and therefore which quota — serves your requests.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button size="sm" variant="outline" disabled={busy || !serverReady} onClick={() => void load()}>
            <RotateCw className="size-3.5" /> Reload
          </Button>
          <Button size="sm" disabled={busy} onClick={() => void addAccount()}>
            <Plus className="size-3.5" /> Add account
          </Button>
        </div>
      </header>

      {notice && (
        <div className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">
          {notice}
        </div>
      )}
      {error && (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      {!serverReady ? (
        <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          opencode serve is not running — accounts are read through its local API.
          <div className="mt-3">
            <Button size="sm" disabled={busy} onClick={() => void startServer()}>
              Start opencode serve
            </Button>
          </div>
        </div>
      ) : orgs === null ? (
        <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          Loading accounts…
        </div>
      ) : groups.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          No console accounts yet. Use{" "}
          <span className="font-medium text-foreground">Add account</span> — it opens{" "}
          <span className="font-mono">opencode console login</span> in a Terminal window (device
          code flow).
        </div>
      ) : (
        <div className="space-y-3">
          {groups.map((group) => {
            const host = hostOf(group.url);
            const activeOrg = group.orgs.find((o) => o.active);
            return (
              <div key={`${group.email}|${group.url}`} className="rounded-lg border border-border">
                <div className="flex items-center justify-between gap-3 border-b border-border px-4 py-2.5">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium">{group.email}</div>
                    <div className="truncate text-xs text-muted-foreground">
                      {host}
                      {activeOrg ? ` · active: ${activeOrg.orgName}` : " · no active org"}
                    </div>
                  </div>
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={busy}
                    onClick={() => void logout(group.email)}
                  >
                    <LogOut className="size-3.5" /> Log out
                  </Button>
                </div>
                <ul className="divide-y divide-border">
                  {group.orgs.map((org) => (
                    <li
                      key={org.orgID}
                      className="flex items-center justify-between gap-3 px-4 py-2.5"
                    >
                      <span className="flex min-w-0 items-center gap-2 text-sm">
                        <span
                          className={cn(
                            "size-2 shrink-0 rounded-full",
                            org.active ? "bg-emerald-500" : "bg-muted-foreground/40",
                          )}
                        />
                        <span className="truncate">{org.orgName}</span>
                        <span className="truncate font-mono text-xs text-muted-foreground">
                          {org.orgID}
                        </span>
                      </span>
                      <Button
                        size="sm"
                        variant={org.active ? "ghost" : "outline"}
                        disabled={busy || org.active}
                        onClick={() => void switchOrg(org)}
                      >
                        {org.active ? "Active" : "Use"}
                      </Button>
                    </li>
                  ))}
                </ul>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}

function hostOf(url: string) {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
