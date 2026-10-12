import { useCallback, useEffect, useState } from "react";
import { FolderOpen, Save } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { getAppInfo } from "@/services/bridge";
import { settingsService, type Settings as AppSettings } from "@/services/settings";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";

interface SettingsPageProps {
  onStatus: (status: OpencodeStatus) => void;
  onGoToUsage: () => void;
}

export function SettingsPage({ onStatus, onGoToUsage }: SettingsPageProps) {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [detected, setDetected] = useState<string | null>(null);
  const [detectingBinary, setDetectingBinary] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [appVersion, setAppVersion] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    setDetectingBinary(true);
    try {
      setSettings(await settingsService.get());
      setDetected(await opencodeService.binary());
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setDetectingBinary(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    void getAppInfo()
      .then((info) => setAppVersion(info.version))
      .catch(() => setAppVersion(null));
  }, []);

  async function save(next: AppSettings, restart = false) {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      setSettings(await settingsService.set(next));
      if (restart) {
        onStatus(await opencodeService.restart());
        setNotice("Saved — opencode serve restarted");
      } else {
        setNotice("Saved");
      }
      setError(null);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }

  if (!settings) {
    return (
      <section aria-busy={detectingBinary} className="page-stack">
        <header className="page-heading">
          <h1 className="page-title">Settings</h1>
        </header>
        <div
          role={error ? "alert" : "status"}
          aria-live={error ? "assertive" : "polite"}
          className="empty-state"
        >
          <span>{error ?? "Loading settings…"}</span>
          {error && (
            <Button size="sm" variant="outline" onClick={() => void load()}>
              Try again
            </Button>
          )}
        </div>
      </section>
    );
  }

  return (
    <section aria-busy={busy || detectingBinary} className="page-stack">
      <header className="page-heading">
        <div className="page-heading__copy">
          <h1 className="page-title">Settings</h1>
          <p className="page-description">
            App behaviour and how this app locates your opencode installation.
          </p>
        </div>
      </header>

      {notice && (
        <div role="status" aria-live="polite" className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">{notice}</div>
      )}
      {error && (
        <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      <div className="settings-layout">
        <section className="switchyard-panel settings-group" aria-labelledby="settings-behavior-heading">
          <h2 id="settings-behavior-heading" className="settings-group__title">App behavior</h2>
          <div className="settings-rows">
            <div className="settings-row">
              <div className="text-sm">
                <div id="settings-auto-start-label" className="font-medium">Start opencode serve on launch</div>
                <div id="settings-auto-start-description" className="text-xs text-muted-foreground">
                  Auto-start the local server the app monitors and controls.
                </div>
              </div>
              <Switch
                aria-labelledby="settings-auto-start-label"
                aria-describedby="settings-auto-start-description"
                checked={settings.autoStart}
                disabled={busy}
                onCheckedChange={(checked) => void save({ ...settings, autoStart: checked })}
              />
            </div>
            <div className="settings-row settings-row--managed">
              <div className="text-sm">
                <div id="settings-auto-rotate-label" className="font-medium">Auto-rotate accounts on quota</div>
                <div id="settings-auto-rotate-description" className="text-xs text-muted-foreground">
                  This quota-specific option has one control on the Usage page.
                </div>
              </div>
              <div className="flex items-center gap-3">
                <span role="status" className="text-xs text-muted-foreground">
                  {settings.autoRotate ? "Enabled" : "Disabled"}
                </span>
                <Button size="sm" variant="outline" onClick={onGoToUsage}>
                  Manage in Usage
                </Button>
              </div>
            </div>
          </div>
        </section>

        <section className="switchyard-panel settings-group" aria-labelledby="settings-installation-heading">
          <h2 id="settings-installation-heading" className="settings-group__title">Installation</h2>
          <div className="settings-rows">
            <div className="settings-row settings-row--stacked">
              <div className="text-sm font-medium">opencode binary</div>
              <div className="text-xs text-muted-foreground">
                Detected:{" "}
                <span className="font-mono">{detected ?? (detectingBinary ? "checking…" : error ? "detection failed" : "not found")}</span>
              </div>
              <div className="flex flex-wrap gap-2">
                <label htmlFor="opencode-binary-path" className="sr-only">opencode binary path</label>
                <input
                  id="opencode-binary-path"
                  aria-describedby="opencode-binary-help"
                  value={settings.opencodeBin ?? ""}
                  onChange={(event) =>
                    setSettings({ ...settings, opencodeBin: event.target.value || null })
                  }
                  placeholder="leave empty to auto-detect (PATH, homebrew, nvm…)"
                  spellCheck={false}
                  className="min-w-0 flex-1 rounded-md border border-input bg-background px-3 py-2 font-mono text-xs outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring focus-visible:outline-2 focus-visible:outline-solid focus-visible:outline-ring focus-visible:outline-offset-2"
                />
                <Button size="sm" disabled={busy} onClick={() => void save(settings, true)}>
                  <Save aria-hidden="true" className="size-3.5" /> Save & restart
                </Button>
              </div>
              <p id="opencode-binary-help" className="text-xs text-muted-foreground">
                This local server resolves OpenCode from its own PATH. Set an absolute path only if
                automatic detection misses your installation (for example, when installed through nvm).
              </p>
            </div>
          </div>
        </section>

        <section className="switchyard-panel settings-group settings-group--cli" aria-labelledby="settings-cli-heading">
          <h2 id="settings-cli-heading" className="settings-group__title">Web app</h2>
          <div className="settings-rows">
            <div className="settings-row settings-row--stacked">
              <div className="text-sm font-medium">Local CLI</div>
              <div className="text-xs text-muted-foreground">
                Version: <span className="font-mono">{appVersion ?? "…"}</span>
              </div>
              <p role="status" className="text-xs text-muted-foreground">
                Start from an OpenCode terminal with <code className="font-mono">relaydock serve</code>.
                Updates are managed by the local project checkout.
              </p>
            </div>
          </div>
        </section>
      </div>

      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        <FolderOpen aria-hidden="true" className="size-3.5" />
        Config lives in this app's config directory (settings.json, proxies.json).
      </div>
    </section>
  );
}
