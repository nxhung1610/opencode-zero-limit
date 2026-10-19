#!/usr/bin/env bash
# Installs, removes, or reports the PATH wrapper that routes `opencode`
# launches through the proxy selected by RelayDock (via the local Edge daemon).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_LAUNCHER="$ROOT/build/relaydock-launch"
SOURCE_EDGE="$ROOT/build/relaydock-edge"
BIN_DIRECTORY="$HOME/.local/bin"
INSTALLED_LAUNCHER="$BIN_DIRECTORY/relaydock-launch"
INSTALLED_EDGE="$BIN_DIRECTORY/relaydock-edge"
COMMAND_LINK="$BIN_DIRECTORY/opencode"
# Keep AGENT_LABEL in sync with EdgeLaunchAgent.label (a unit test pins this).
AGENT_LABEL="com.nxhung.relaydock.edge"
AGENT_PLIST_DIRECTORY="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_PLIST_DIRECTORY/$AGENT_LABEL.plist"

usage() {
  echo "Usage: scripts/opencode-wrapper.sh <install|uninstall|status>" >&2
  exit 2
}

require_build() {
  if [[ ! -x "$SOURCE_LAUNCHER" || ! -x "$SOURCE_EDGE" ]]; then
    echo "Launcher and/or Edge not built yet; running scripts/build-launcher.sh…" >&2
    "$ROOT/scripts/build-launcher.sh"
  fi
}

report_path_order() {
  case ":$PATH:" in
    *":$BIN_DIRECTORY:"*) ;;
    *) echo "Notice: $BIN_DIRECTORY is not in PATH; add it so the wrapper is found." >&2 ;;
  esac
  local resolved
  resolved="$(command -v opencode || true)"
  if [[ "$resolved" == "$COMMAND_LINK" ]]; then
    echo "OK: 'opencode' resolves to the wrapper."
  elif [[ -n "$resolved" ]]; then
    echo "Notice: 'opencode' resolves to $resolved — an earlier PATH entry wins, so the wrapper will not intercept launches until PATH order changes." >&2
  fi
}

install() {
  require_build
  # The install itself lives in the binary (single source of truth:
  # EdgeInstaller) so the app and this script drive one code path. The script
  # only supplies the built launcher binary; HOME, PATH, RELAYDOCK_CONFIG_DIR,
  # and RELAYDOCK_LAUNCHCTL pass straight through.
  "$SOURCE_EDGE" install --launcher "$SOURCE_LAUNCHER"
}

uninstall() {
  # Prefer the installed binary: it knows its own layout and keeps working
  # when this checkout is gone. Binaries from before the `uninstall`
  # subcommand exit non-zero here, so the built binary is the fallback.
  if [[ -x "$INSTALLED_EDGE" ]] && "$INSTALLED_EDGE" uninstall; then
    return 0
  fi
  require_build
  "$SOURCE_EDGE" uninstall
}

status() {
  if [[ -L "$COMMAND_LINK" ]]; then
    echo "wrapper: $COMMAND_LINK -> $(readlink "$COMMAND_LINK")"
    report_path_order
  else
    echo "wrapper: not installed"
  fi
  if [[ -f "$AGENT_PLIST" ]]; then
    if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
      echo "launchd agent: $AGENT_PLIST (loaded)"
    else
      echo "launchd agent: $AGENT_PLIST (installed, not loaded)"
    fi
  else
    echo "launchd agent: not installed"
  fi
  if [[ -x "$INSTALLED_EDGE" ]]; then
    echo "edge binary: $INSTALLED_EDGE"
    "$INSTALLED_EDGE" status || true
  else
    echo "edge binary: not installed"
  fi
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  *) usage ;;
esac
