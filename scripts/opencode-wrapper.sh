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
CONFIG_DIRECTORY="${RELAYDOCK_CONFIG_DIR:-$HOME/Library/Application Support/com.nxhung.opencodezerolimit}"
EDGE_CONFIG="$CONFIG_DIRECTORY/edge.json"

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
  mkdir -p "$BIN_DIRECTORY"
  if [[ -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    echo "Refusing to replace $COMMAND_LINK: it exists and is not a symlink." >&2
    exit 1
  fi
  # Upgrade path: stop a stale instance so the new binary takes over on the
  # next launch (spawn-on-demand; the installer never starts Edge itself).
  # Nothing to stop on a cold install — that is not an error.
  if [[ -x "$INSTALLED_EDGE" ]]; then
    "$INSTALLED_EDGE" stop >/dev/null 2>&1 || true
  fi
  cp -f "$SOURCE_LAUNCHER" "$INSTALLED_LAUNCHER"
  cp -f "$SOURCE_EDGE" "$INSTALLED_EDGE"
  ln -sfn "$INSTALLED_LAUNCHER" "$COMMAND_LINK"
  # First install: probe a free loopback port and generate the token. On
  # upgrades the existing edge.json is kept — the port never renumbers once
  # consumers hold it.
  "$INSTALLED_EDGE" init
  echo "Installed $COMMAND_LINK -> $INSTALLED_LAUNCHER"
  echo "Installed $INSTALLED_EDGE"
  report_path_order
  cat <<'HINT'

Apply routing to OpenCode's background service (it performs model calls):
  opencode service stop && opencode service start   # interrupts active sessions

Inspect Edge and a launch:
  relaydock-edge status
  ps eww -p <opencode pid> | tr ' ' '\n' | grep -i proxy
  lsof -nP -iTCP -a -p <opencode pid> | grep ESTABLISHED

The app's honesty note still applies — the routing line reports the
environment the wrapper set, not verified traffic.
HINT
}

uninstall() {
  if [[ -x "$INSTALLED_EDGE" ]]; then
    "$INSTALLED_EDGE" stop >/dev/null 2>&1 || true
  fi
  if [[ -L "$COMMAND_LINK" ]]; then
    rm -f "$COMMAND_LINK"
    echo "Removed $COMMAND_LINK"
  else
    echo "No wrapper symlink at $COMMAND_LINK"
  fi
  if [[ -f "$INSTALLED_LAUNCHER" ]]; then
    rm -f "$INSTALLED_LAUNCHER"
    echo "Removed $INSTALLED_LAUNCHER"
  fi
  if [[ -f "$INSTALLED_EDGE" ]]; then
    rm -f "$INSTALLED_EDGE"
    echo "Removed $INSTALLED_EDGE"
  fi
  if [[ -f "$EDGE_CONFIG" ]]; then
    rm -f "$EDGE_CONFIG"
    echo "Removed $EDGE_CONFIG"
  fi
  echo "Kept the proxy pool and Edge script cache (user data) in: $CONFIG_DIRECTORY"
}

status() {
  if [[ -L "$COMMAND_LINK" ]]; then
    echo "wrapper: $COMMAND_LINK -> $(readlink "$COMMAND_LINK")"
    report_path_order
  else
    echo "wrapper: not installed"
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
