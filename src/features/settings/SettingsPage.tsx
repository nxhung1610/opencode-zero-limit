import { useCallback, useEffect, useState } from "react";
import { FolderOpen, Save, Settings } from "lucide-react";
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
        <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
          <FolderOpen className="size-3.5" />
          Config lives in this app's config directory (settings.json, proxies.json).
        </div>
      </div>
    </section>
  );
}
