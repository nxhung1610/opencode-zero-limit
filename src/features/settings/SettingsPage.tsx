import { useCallback, useEffect, useState } from "react";
import { Download, FolderOpen, RefreshCw, Save, Settings } from "lucide-react";
import { getVersion } from "@tauri-apps/api/app";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { settingsService, type Settings as AppSettings } from "@/services/settings";
import { opencodeService, type OpencodeStatus } from "@/services/opencode";

interface SettingsPageProps {
  onStatus: (status: OpencodeStatus) => void;
}

export function SettingsPage({ onStatus }: SettingsPageProps) {
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [detected, setDetected] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const [update, setUpdate] = useState<Update | null>(null);
  const [updating, setUpdating] = useState(false);
  const [progress, setProgress] = useState<number | null>(null);
  const [updateNote, setUpdateNote] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setSettings(await settingsService.get());
      setDetected(await opencodeService.binary());
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    void getVersion()
      .then(setAppVersion)
      .catch(() => setAppVersion(null));
  }, []);

  async function checkForUpdates() {
    setUpdating(true);
    setUpdate(null);
    setUpdateNote(null);
    try {
      const found = await check();
      if (found) {
        setUpdate(found);
        setUpdateNote(`v${found.version} available${found.body ? ` — ${found.body}` : ""}`);
      } else {
        setUpdateNote("up to date");
      }
    } catch (e) {
      setUpdateNote(`check failed: ${String(e)}`);
    } finally {
      setUpdating(false);
    }
  }

  async function installUpdate() {
    if (!update) return;
    setUpdating(true);
    setProgress(0);
    try {
      await update.downloadAndInstall((event) => {
        if (event.event === "Started") {
          setProgress(0);
        } else if (event.event === "Finished") {
          setProgress(100);
        }
      });
      setUpdateNote("installed — restart the app to apply");
      setUpdate(null);
    } catch (e) {
      setUpdateNote(`install failed: ${String(e)}`);
    } finally {
      setUpdating(false);
      setProgress(null);
    }
  }

  async function save(next: AppSettings, restart = false) {
    setBusy(true);
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
      <section className="space-y-4">
        <h1 className="flex items-center gap-2 text-lg font-semibold">
          <Settings className="size-5" /> Settings
        </h1>
        <div className="rounded-lg border border-dashed border-border p-6 text-sm text-muted-foreground">
          {error ?? "Loading settings…"}
        </div>
      </section>
    );
  }

  return (
    <section className="space-y-4">
      <header className="space-y-1">
        <h1 className="flex items-center gap-2 text-lg font-semibold">
          <Settings className="size-5" /> Settings
        </h1>
        <p className="text-sm text-muted-foreground">
          App behaviour and how this app locates your opencode installation.
        </p>
      </header>

      {notice && (
        <div className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">{notice}</div>
      )}
      {error && (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs text-destructive">
          {error}
        </div>
      )}

      <div className="flex items-center justify-between gap-4 rounded-lg border border-border px-4 py-3">
        <div className="text-sm">
          <div className="font-medium">Start opencode serve on launch</div>
          <div className="text-xs text-muted-foreground">
            Auto-start the local server the app monitors and controls.
          </div>
        </div>
        <Switch
          checked={settings.autoStart}
          disabled={busy}
          onCheckedChange={(checked) => void save({ ...settings, autoStart: checked })}
        />
      </div>

      <div className="flex items-center justify-between gap-4 rounded-lg border border-border px-4 py-3">
        <div className="text-sm">
          <div className="font-medium">Auto-rotate accounts on quota</div>
          <div className="text-xs text-muted-foreground">
            Mirrors the toggle on the Usage page.
          </div>
        </div>
        <Switch
          checked={settings.autoRotate}
          disabled={busy}
          onCheckedChange={(checked) => void save({ ...settings, autoRotate: checked })}
        />
      </div>

      <div className="rounded-lg border border-border px-4 py-3">
        <div className="text-sm font-medium">opencode binary</div>
        <div className="mt-1 mb-2 text-xs text-muted-foreground">
          Detected:{" "}
          <span className="font-mono">{detected ?? "not found"}</span>
        </div>
        <div className="flex gap-2">
          <input
            value={settings.opencodeBin ?? ""}
            onChange={(event) =>
              setSettings({ ...settings, opencodeBin: event.target.value || null })
            }
            placeholder="leave empty to auto-detect (PATH, homebrew, nvm…)"
            spellCheck={false}
            className="min-w-0 flex-1 rounded-md border border-input bg-background px-3 py-2 font-mono text-xs outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
          />
          <Button
            size="sm"
            disabled={busy}
            onClick={() => void save(settings, true)}
          >
            <Save className="size-3.5" /> Save & restart
          </Button>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          GUI apps inherit a stripped PATH — if spawn fails, paste the full path here (e.g.
          <span className="font-mono"> /Users/you/.nvm/versions/node/v24.21.0/bin/opencode</span>).
        </p>
      </div>

      <div className="rounded-lg border border-border px-4 py-3">
        <div className="text-sm font-medium">Updates</div>
        <div className="mt-1 mb-2 text-xs text-muted-foreground">
          Current version: <span className="font-mono">{appVersion ?? "…"}</span>
          {updateNote ? ` · ${updateNote}` : ""}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button size="sm" variant="outline" disabled={updating} onClick={() => void checkForUpdates()}>
            <RefreshCw className="size-3.5" /> Check for updates
          </Button>
          {update && (
            <Button size="sm" disabled={updating} onClick={() => void installUpdate()}>
              <Download className="size-3.5" /> Install v{update.version}
              {progress === 100 ? " (done)" : progress !== null ? " (downloading…)" : ""}
            </Button>
          )}
        </div>
      </div>

      <div className="flex items-center gap-2 text-xs text-muted-foreground">
        <FolderOpen className="size-3.5" />
        Config lives in this app's config directory (settings.json, proxies.json).
      </div>
    </section>
  );
}
