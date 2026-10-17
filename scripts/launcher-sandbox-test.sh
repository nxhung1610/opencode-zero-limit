#!/usr/bin/env bash
# Hermetic sandbox test for the RelayDock `opencode` wrapper.
#
# Runs the real launcher through a throwaway config directory, a stub
# `opencode` command, and fake localhost services — no real OpenCode CLI, no
# provider accounts, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/build/relaydock-launch"

if [[ ! -x "$LAUNCHER" ]]; then
  echo "Launcher not built yet; running scripts/build-launcher.sh…" >&2
  "$ROOT/scripts/build-launcher.sh"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-launcher-test.XXXXXX")"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

CONFIG="$WORK/config"
STUB_DIRECTORY="$WORK/stub-bin"
LINK_DIRECTORY="$WORK/link-bin"
RECORD="$WORK/stub-record"
mkdir -p "$CONFIG" "$STUB_DIRECTORY" "$LINK_DIRECTORY"

# --- fake provider + fake proxy --------------------------------------------
read -r PROVIDER_PORT PROXY_PORT <<< "$(python3 - <<'PYEOF'
import socket
a = socket.socket(); a.bind(("127.0.0.1", 0))
b = socket.socket(); b.bind(("127.0.0.1", 0))
print(a.getsockname()[1], b.getsockname()[1])
a.close(); b.close()
PYEOF
)"
COUNT_FILE="$WORK/provider-count"
PROXY_LOG="$WORK/proxy-log"

cat > "$WORK/fake-services.py" <<'PYEOF'
import http.server
import socketserver
import sys
import threading

count_file, proxy_log = sys.argv[1], sys.argv[2]
provider_port, proxy_port = int(sys.argv[3]), int(sys.argv[4])


class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        count = 0
        try:
            with open(count_file) as handle:
                count = int(handle.read().strip() or "0")
        except FileNotFoundError:
            pass
        count += 1
        with open(count_file, "w") as handle:
            handle.write(str(count))
        body = f"http://127.0.0.1:{proxy_port}".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(8192)
        line = data.split(b"\r\n", 1)[0].decode(errors="replace")
        with open(proxy_log, "a") as handle:
            handle.write(line + "\n")
        self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")


threading.Thread(
    target=lambda: http.server.HTTPServer(("127.0.0.1", provider_port), Provider).serve_forever(),
    daemon=True,
).start()
socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", proxy_port), ProxyHandler) as server:
    server.serve_forever()
PYEOF

python3 "$WORK/fake-services.py" "$COUNT_FILE" "$PROXY_LOG" "$PROVIDER_PORT" "$PROXY_PORT" &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true

for _ in $(seq 1 25); do
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PROVIDER_PORT/count" && break
  sleep 0.2
done
rm -f "$COUNT_FILE"

# --- stub opencode ----------------------------------------------------------
cat > "$STUB_DIRECTORY/opencode" <<STUBEOF
#!/bin/sh
echo "\$@" > "$RECORD.args"
env > "$RECORD.env"
rm -f "$RECORD.proxy"
if [ -n "\${HTTP_PROXY:-}" ]; then
  curl -s --max-time 10 -x "\$HTTP_PROXY" http://relaydock.test/health -o /dev/null -w '%{http_code}' > "$RECORD.proxy" || echo "curl-failed" > "$RECORD.proxy"
fi
exit 0
STUBEOF
chmod +x "$STUB_DIRECTORY/opencode"

# The wrapper symlink also lives first in PATH: the launcher must skip it and
# find the stub after it.
ln -sfn "$LAUNCHER" "$LINK_DIRECTORY/opencode"

write_store() {  # $1 = mode, $2 = script
  python3 - "$CONFIG/proxies.json" "$1" "$2" <<'PYEOF'
import json
import sys

path, mode, script = sys.argv[1], sys.argv[2], sys.argv[3]
state = {
    "mode": mode,
    "proxies": [
        {"id": "px_sandbox", "label": "Sandbox", "url": "", "script": script, "enabled": True}
    ],
    "bindings": {},
}
with open(path, "w") as handle:
    json.dump(state, handle)
PYEOF
}

CACHING_SCRIPT="if (cache.url && cache.expiresAt && Date.now() < cache.expiresAt) { return cache.url; }
const url = (await (await fetch(\"http://127.0.0.1:$PROVIDER_PORT/count\")).text()).trim();
cache.url = url;
cache.expiresAt = Date.now() + 60 * 60 * 1000;
return cache.url;"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
check() {  # $1 = description, rest = command
  local description="$1"
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

run_launcher() {
  OPENCODE_SERVER_PASSWORD="should-not-leak" \
  RELAYDOCK_QUIET="${RELAYDOCK_QUIET:-}" \
  RELAYDOCK_CONFIG_DIR="$CONFIG" \
  PATH="$LINK_DIRECTORY:$STUB_DIRECTORY:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$LINK_DIRECTORY/opencode" "$@" > "$WORK/stdout" 2> "$WORK/stderr"
}

echo "== scenario 1: script resolves through the provider =="
write_store auto "$CACHING_SCRIPT"
rm -f "$COUNT_FILE" "$PROXY_LOG" "$RECORD.args" "$RECORD.env" "$RECORD.proxy" "$CONFIG/launcher-cache.json"
run_launcher hello
check "stub received the arguments" grep -q "^hello$" "$RECORD.args"
check "HTTP_PROXY points at the fake proxy" grep -q "^HTTP_PROXY=http://127.0.0.1:$PROXY_PORT$" "$RECORD.env"
check "NO_PROXY covers localhost" grep -qE "^NO_PROXY=.*127\.0\.0\.1" "$RECORD.env"
check "provider was called once" test "$(cat "$COUNT_FILE" 2>/dev/null)" = "1"
check "stub traffic went through the proxy" grep -q "relaydock.test" "$PROXY_LOG"
check "stub reached the proxy successfully" grep -q "^200$" "$RECORD.proxy"
check "routing line names the entry" grep -q "RelayDock: routed via Sandbox" "$WORK/stderr"
check "cache file was written" test -s "$CONFIG/launcher-cache.json"
check "cache file records the entry" grep -q "px_sandbox" "$CONFIG/launcher-cache.json"
if grep -q "^OPENCODE_SERVER_PASSWORD=" "$RECORD.env"; then
  fail "OPENCODE_SERVER_PASSWORD was removed from the child"
else
  pass "OPENCODE_SERVER_PASSWORD was removed from the child"
fi

echo "== scenario 2: cache survives into the next launch =="
run_launcher hello2
check "stub ran again" grep -q "^hello2$" "$RECORD.args"
check "provider was not called again" test "$(cat "$COUNT_FILE" 2>/dev/null)" = "1"
check "traffic went through the proxy again" test "$(grep -c relaydock.test "$PROXY_LOG")" -ge 2

echo "== scenario 3: script failure is fail-closed =="
write_store auto 'throw new Error("sandbox: provider unavailable");'
rm -f "$RECORD.args"
set +e
run_launcher should-not-run
STATUS=$?
set -e
check "launcher exited non-zero" test "$STATUS" -ne 0
if [[ -f "$RECORD.args" ]]; then
  fail "stub did not run"
else
  pass "stub did not run"
fi
check "stderr explains the failure" grep -q "was not started" "$WORK/stderr"

echo "== scenario 4: an edited script invalidates the cached snapshot =="
write_store auto "// edited
$CACHING_SCRIPT"
rm -f "$RECORD.args"
run_launcher after-edit
check "stub ran with the edited script" grep -q "^after-edit$" "$RECORD.args"
check "provider was called again for the new script" test "$(cat "$COUNT_FILE" 2>/dev/null)" = "2"

echo "== scenario 5: Off mode launches without a proxy =="
write_store off "$CACHING_SCRIPT"
rm -f "$RECORD.args" "$RECORD.env" "$RECORD.proxy"
run_launcher plain
check "stub ran in Off mode" grep -q "^plain$" "$RECORD.args"
if grep -qE "^(HTTP|HTTPS|ALL)_PROXY=" "$RECORD.env"; then
  fail "Off mode set no proxy variables"
else
  pass "Off mode set no proxy variables"
fi
check "stderr reports Off mode" grep -q "proxy mode is Off" "$WORK/stderr"

echo "== scenario 6: RELAYDOCK_QUIET=1 silences the routing line =="
RELAYDOCK_QUIET=1
run_launcher quiet-run
unset RELAYDOCK_QUIET
check "stub still ran" grep -q "^quiet-run$" "$RECORD.args"
if [[ -s "$WORK/stderr" ]]; then
  fail "stderr is empty with RELAYDOCK_QUIET=1"
else
  pass "stderr is empty with RELAYDOCK_QUIET=1"
fi

echo "== scenario 7: the command replaces the launcher (terminal job control) =="
# A child in its own process group is SIGTTIN-stopped when a full-screen TUI
# reads the terminal. The launcher must exec the command instead, so the
# process (pid) and its foreground group survive.
RELAYDOCK_CONFIG_DIR="$CONFIG" bash -c 'set -m; "$1" sh -c "echo \$\$" > "$2/replace-child.pid" & JOB=$!; wait "$JOB"; echo "$JOB" > "$2/replace-job.pid"' _ "$LAUNCHER" "$WORK"
check "command runs as the launcher process (same pid)" test "$(cat "$WORK/replace-child.pid")" = "$(cat "$WORK/replace-job.pid")"
PTY_OUTPUT="$(RELAYDOCK_CONFIG_DIR="$CONFIG" PATH="$LINK_DIRECTORY:$STUB_DIRECTORY:/usr/bin:/bin:/usr/sbin:/sbin" \
  script -q /dev/null "$LAUNCHER" sh -c 'PG=$(ps -o pgid= -p $$ | tr -d " "); TP=$(ps -o tpgid= -p $$ | tr -d " "); if [ "$PG" = "$TP" ]; then echo FOREGROUND; else echo BACKGROUND; fi' 2>/dev/null | tr -d "\r")"
check "command keeps the terminal foreground group" grep -q FOREGROUND <<< "$PTY_OUTPUT"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All sandbox checks passed."
else
  echo "$FAILURES sandbox check(s) failed." >&2
  exit 1
fi
