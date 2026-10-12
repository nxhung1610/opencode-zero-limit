import { useState, type ReactNode } from "react";
import { Check } from "lucide-react";
import { Button } from "@/components/ui/button";

type AccountState = "loading" | "error" | "empty" | "ready";
type StepStatus = "complete" | "current" | "upcoming" | "optional";

interface SetupGuideProps {
  serverReady: boolean;
  statusLoading: boolean;
  accountState: AccountState;
  hasActiveAccount: boolean;
  onGoToUsage: () => void;
  onGoToProxies: () => void;
  onGoToSettings: () => void;
}

const STORAGE_KEY = "relaydock.setup-guide-dismissed.v1";
const LEGACY_STORAGE_KEY = "opencode-zero-limit.setup-guide-dismissed.v1";

function wasDismissed() {
  try {
    const dismissed =
      localStorage.getItem(STORAGE_KEY) === "true" ||
      localStorage.getItem(LEGACY_STORAGE_KEY) === "true";
    if (dismissed) localStorage.setItem(STORAGE_KEY, "true");
    return dismissed;
  } catch {
    return false;
  }
}

export function SetupGuide({
  serverReady,
  statusLoading,
  accountState,
  hasActiveAccount,
  onGoToUsage,
  onGoToProxies,
  onGoToSettings,
}: SetupGuideProps) {
  const [dismissed, setDismissed] = useState(wasDismissed);
  const [revealed, setRevealed] = useState(false);
  const accountReady = accountState === "ready";
  const activeAccountReady = accountReady && hasActiveAccount;
  const collapsed = dismissed || (activeAccountReady && !revealed);

  function finish() {
    try {
      localStorage.setItem(STORAGE_KEY, "true");
    } catch {
      // Keep the guide dismissible for this session if storage is unavailable.
    }
    setDismissed(true);
    setRevealed(false);
  }

  function showGuide() {
    setDismissed(false);
    setRevealed(true);
  }

  if (collapsed) {
    return (
      <div className="setup-guide__collapsed">
        <span className="setup-guide__collapsed-label">
          {activeAccountReady && <Check aria-hidden="true" className="size-3.5" />}
          {activeAccountReady ? "Setup complete" : "Setup guide"}
        </span>
        <Button size="sm" variant="ghost" onClick={showGuide}>
          Show setup guide
        </Button>
      </div>
    );
  }

  return (
    <aside aria-labelledby="setup-guide-heading" className="switchyard-panel setup-guide">
      <header className="setup-guide__header">
        <div>
          <h2 id="setup-guide-heading" className="setup-guide__title">Get started</h2>
          <p className="setup-guide__copy">
            Start the local service, connect a Console account in your browser, then review optional routing and automation.
          </p>
        </div>
        <Button size="sm" variant="ghost" onClick={finish}>
          {activeAccountReady ? "Finish setup" : "Not now"}
        </Button>
      </header>

      <ol aria-label="Setup steps" className="setup-track">
        <StepCard
          number={1}
          title="Start opencode serve"
          status={serverReady ? "complete" : "current"}
          description={
            serverReady
              ? "The local service is running."
              : statusLoading
                ? "Checking local service status…"
                : "Use Start in the top bar to launch the local service this app monitors and controls."
          }
        />

        <StepCard
          number={2}
          title="Connect a Console account"
          status={accountReady ? "complete" : serverReady ? "current" : "upcoming"}
          description={
            accountReady
              ? "OpenCode Console credentials are saved in its local database."
              : !serverReady
                ? "After the service starts, generate a browser sign-in link."
                : accountState === "loading"
                  ? "Checking saved Console connections…"
                  : accountState === "error"
                    ? "Could not verify saved connections. Use Reload or Add account above."
                    : "Use Add account to generate a sign-in link, then authorize in your browser."
          }
        />

        <StepCard
          number={3}
          title="Choose the active account"
          status={activeAccountReady ? "complete" : accountReady ? "current" : "upcoming"}
          description={
            activeAccountReady
              ? "The selected OpenCode Console connection is active."
              : accountReady
                ? "Choose which saved connection OpenCode should use for requests."
                : "After signing in, select the Console account to use for requests."
          }
        />

        <StepCard
          number={4}
          title="Configure optional features"
          status="optional"
          description="Usage shows local counters, not remaining quota. Review auto-rotation, proxy routing, or the binary path when needed."
        >
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="outline" onClick={onGoToUsage}>Usage</Button>
            <Button size="sm" variant="outline" onClick={onGoToProxies}>Proxies</Button>
            <Button size="sm" variant="outline" onClick={onGoToSettings}>Settings</Button>
          </div>
        </StepCard>
      </ol>
    </aside>
  );
}

function StepCard({
  number,
  title,
  status,
  description,
  children,
}: {
  number: number;
  title: string;
  status: StepStatus;
  description: string;
  children?: ReactNode;
}) {
  const complete = status === "complete";
  const statusLabel = complete
    ? "Complete"
    : status === "current"
      ? "Next"
      : status === "optional"
        ? "Optional"
        : "Later";

  return (
    <li
      aria-current={status === "current" ? "step" : undefined}
      className="setup-track__step"
      data-status={status}
    >
      <span aria-hidden="true" className="setup-track__marker">
        {complete ? <Check className="size-3.5" /> : number}
      </span>
      <div className="min-w-0">
        <div className="setup-track__heading">
          <h3 className="setup-track__title">{title}</h3>
          <span className="setup-track__status">{statusLabel}</span>
        </div>
        <p className="setup-track__description">{description}</p>
        {children && <div className="setup-track__actions">{children}</div>}
      </div>
    </li>
  );
}
