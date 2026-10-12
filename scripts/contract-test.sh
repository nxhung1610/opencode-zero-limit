#!/usr/bin/env bash
# Contract test against a pinned opencode version.
# Verifies the local HTTP API surface this app depends on.
set -euo pipefail

PORT="${OPENCODE_CONTRACT_PORT:-4096}"
LOG=$(mktemp "${TMPDIR:-/tmp}/relaydock-contract-serve.XXXXXX")
DOC_PATH=$(mktemp "${TMPDIR:-/tmp}/relaydock-contract-doc.XXXXXX")
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -f "$DOC_PATH" "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

opencode serve --port "$PORT" --hostname 127.0.0.1 >"$LOG" 2>&1 &
SERVE_PID=$!

echo "waiting for opencode serve on :${PORT}..."
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/global/health" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" = 60 ]; then
    echo "serve never became healthy"; cat "$LOG"; exit 1
  fi
  sleep 0.5
done

curl -fsS "http://127.0.0.1:$PORT/global/health" | python3 -c 'import json,sys; health=json.load(sys.stdin); assert isinstance(health.get("healthy"), bool) and isinstance(health.get("version"), str), health'
curl -fsS "http://127.0.0.1:$PORT/doc" -o "$DOC_PATH"

python3 - "$DOC_PATH" <<'EOF'
import json, sys

required = [
    "/global/health",
    "/event",
    "/auth/{providerID}",
    "/experimental/console",
    "/experimental/console/orgs",
    "/experimental/console/switch",
]
doc = json.load(open(sys.argv[1]))
paths = doc["paths"]

missing = [p for p in required if p not in paths]
if missing:
    print("MISSING CONTRACT PATHS:", missing)
    sys.exit(1)

switch = paths["/experimental/console/switch"]
assert "post" in switch, "console/switch must accept POST"
print(f"contract OK: {len(paths)} paths, all {len(required)} required present")
EOF

echo "health shape:"
curl -s "http://127.0.0.1:$PORT/global/health"
echo
