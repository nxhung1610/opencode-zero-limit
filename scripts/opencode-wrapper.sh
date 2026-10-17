#!/usr/bin/env bash
# Installs, removes, or reports the PATH wrapper that routes `opencode`
# launches through the proxy selected by RelayDock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_LAUNCHER="$ROOT/build/relaydock-launch"
BIN_DIRECTORY="$HOME/.local/bin"
INSTALLED_LAUNCHER="$BIN_DIRECTORY/relaydock-launch"
COMMAND_LINK="$BIN_DIRECTORY/opencode"

usage() {
  echo "Usage: scripts/opencode-wrapper.sh <install|uninstall|status>" >&2
  exit 2
}

require_build() {
  if [[ ! -x "$SOURCE_LAUNCHER" ]]; then
    echo "Launcher not built yet; running scripts/build-launcher.sh…" >&2
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
  cp -f "$SOURCE_LAUNCHER" "$INSTALLED_LAUNCHER"
  ln -sfn "$INSTALLED_LAUNCHER" "$COMMAND_LINK"
  echo "Installed $COMMAND_LINK -> $INSTALLED_LAUNCHER"
  report_path_order
  cat <<'HINT'

Apply routing to OpenCode's background service (it performs model calls):
  opencode service stop && opencode service start   # interrupts active sessions

Verify a launch independently (the app's honesty note still applies — the
routing line reports the environment the wrapper set, not verified traffic):
  ps eww -p <opencode pid> | tr ' ' '\n' | grep -i proxy
  lsof -nP -iTCP -a -p <opencode pid> | grep ESTABLISHED
HINT
}

uninstall() {
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
}

status() {
  if [[ -L "$COMMAND_LINK" ]]; then
    echo "wrapper: $COMMAND_LINK -> $(readlink "$COMMAND_LINK")"
    report_path_order
  else
    echo "wrapper: not installed"
  fi
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  *) usage ;;
esac
