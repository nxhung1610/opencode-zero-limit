#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${OPENCODE_BIN:-$(command -v opencode || true)}"
if [[ -z "$BINARY" || ! -x "$BINARY" ]]; then
  echo "OpenCode CLI not found. Install it or set OPENCODE_BIN=/path/to/opencode." >&2
  exit 2
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-opencode-smoke.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/config" "$TEMP_ROOT/data" "$TEMP_ROOT/cache"

HOME="$TEMP_ROOT/home" \
XDG_CONFIG_HOME="$TEMP_ROOT/config" \
XDG_DATA_HOME="$TEMP_ROOT/data" \
XDG_CACHE_HOME="$TEMP_ROOT/cache" \
OPENCODE_BIN="$BINARY" \
swift test --package-path "$ROOT/macOS/RelayDock" --filter OpenCodeInstalledSmokeTests
