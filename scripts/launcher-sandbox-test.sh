#!/usr/bin/env bash
# Hermetic sandbox test for the RelayDock wrapper + Edge daemon.
#
# Runs the real launcher and the real `relaydock-edge` through a throwaway
# config directory, a stub `opencode` command, and fake localhost services —
# no real OpenCode CLI, no provider accounts, no network. Covers the P1
# acceptance paths: cold launch, warm/sticky launch, rotation without a
# process restart, script-edit invalidation, the token gate, fail-closed
# behaviour, the spawn race, crash respawn, and job control.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/build/relaydock-launch"
EDGE="$ROOT/build/relaydock-edge"

if [[ ! -x "$LAUNCHER" || ! -x "$EDGE" ]]; then
  echo "Launcher and/or Edge not built yet; running scripts/build-launcher.sh…" >&2
  "$ROOT/scripts/build-launcher.sh"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-sandbox-test.XXXXXX")"
PROVIDER_PID=""
PROXY_A_PID=""
PROXY_B_PID=""
OCCUPANT_PID=""
cleanup() {
  for pid in "$PROVIDER_PID" "$PROXY_A_PID" "$PROXY_B_PID" "$OCCUPANT_PID"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  "$EDGE" stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

CONFIG="$WORK/config"
STUB_DIRECTORY="$WORK/stub-bin"
LINK_DIRECTORY="$WORK/link-bin"
RECORD="$WORK/stub-record"
mkdir -p "$CONFIG" "$STUB_DIRECTORY" "$LINK_DIRECTORY"
export RELAYDOCK_CONFIG_DIR="$CONFIG"

# --- fake provider + fake proxies -------------------------------------------
read -r PROVIDER_PORT PROXY_A_PORT PROXY_B_PORT <<< "$(python3 - <<'PYEOF'
import socket
ports = []
for _ in range(3):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    ports.append(s.getsockname()[1])
    s.close()
print(*ports)
PYEOF
)"
COUNT_FILE="$WORK/provider-count"
PROXY_LOG_A="$WORK/proxy-log-a"
PROXY_LOG_B="$WORK/proxy-log-b"

cat > "$WORK/fake-services.py" <<'PYEOF'
import http.server
import socketserver
import sys

mode = sys.argv[1]

if mode == "provider":
    count_file, proxy_a, proxy_b, port = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

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
            # First resolution gets proxy A; every later one gets proxy B, so
            # the tests can prove a re-resolve actually re-ran the script.
            body = f"http://127.0.0.1:{proxy_a if count == 1 else proxy_b}".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("127.0.0.1", port), Provider).serve_forever()
else:
    proxy_log, tag, port = sys.argv[2], sys.argv[3], int(sys.argv[4])

    class ProxyHandler(socketserver.BaseRequestHandler):
        def handle(self):
            data = self.request.recv(8192)
            line = data.split(b"\r\n", 1)[0].decode(errors="replace")
            with open(proxy_log, "a") as handle:
                handle.write(f"[{tag}] {line}\n")
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", port), ProxyHandler) as server:
        server.serve_forever()
PYEOF

python3 "$WORK/fake-services.py" provider "$COUNT_FILE" "$PROXY_A_PORT" "$PROXY_B_PORT" "$PROVIDER_PORT" &
PROVIDER_PID=$!
python3 "$WORK/fake-services.py" proxy "$PROXY_LOG_A" A "$PROXY_A_PORT" &
PROXY_A_PID=$!
python3 "$WORK/fake-services.py" proxy "$PROXY_LOG_B" B "$PROXY_B_PORT" &
PROXY_B_PID=$!

for _ in $(seq 1 25); do
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PROVIDER_PORT/count" && break
  sleep 0.2
done
rm -f "$COUNT_FILE"

# --- edge configuration -----------------------------------------------------
"$EDGE" init > /dev/null
EDGE_PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$CONFIG/edge.json")"
EDGE_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$CONFIG/edge.json")"

# --- stub opencode ----------------------------------------------------------
cat > "$STUB_DIRECTORY/opencode" <<STUBEOF
#!/bin/sh
echo "\$@" >> "$RECORD.args"
env > "$RECORD.env"
rm -f "$RECORD.proxy"
if [ -n "\${HTTP_PROXY:-}" ]; then
  code="\$(curl -s --max-time 10 -x "\$HTTP_PROXY" http://relaydock.test/health -o /dev/null -w '%{http_code}' || true)"
  [ -n "\$code" ] || code=curl-failed
  echo "\$code" > "$RECORD.proxy"
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

edge_pid() { lsof -nP -iTCP:"$EDGE_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1; }
edge_stop() { "$EDGE" stop >/dev/null 2>&1 || true; }
provider_count() { cat "$COUNT_FILE" 2>/dev/null || echo 0; }

echo "== scenario 1: cold launch spawns Edge on demand and routes through it =="
write_store auto "$CACHING_SCRIPT"
edge_stop
rm -f "$COUNT_FILE" "$PROXY_LOG_A" "$RECORD.args" "$RECORD.env" "$RECORD.proxy" "$CONFIG/edge.log" "$CONFIG/script-cache.json"
run_launcher hello
check "stub received the arguments" grep -q "^hello$" "$RECORD.args"
check "stub reached the proxy successfully" grep -q "^200$" "$RECORD.proxy"
check "HTTP_PROXY is the constant Edge carrier URL" grep -qx "HTTP_PROXY=http://$EDGE_TOKEN:@127.0.0.1:$EDGE_PORT" "$RECORD.env"
check "ALL_PROXY carries the same constant URL" grep -qx "ALL_PROXY=http://$EDGE_TOKEN:@127.0.0.1:$EDGE_PORT" "$RECORD.env"
check "NO_PROXY covers localhost" grep -qE "^NO_PROXY=.*127\.0\.0\.1" "$RECORD.env"
check "Edge was spawned" test -n "$(edge_pid)"
check "Edge resolved through the provider" test "$(provider_count)" -ge 1
check "stub traffic went through proxy A" grep -q "relaydock.test" "$PROXY_LOG_A"
check "routing line reports Edge" grep -q "RelayDock: routed via Edge on 127.0.0.1:$EDGE_PORT" "$WORK/stderr"
check "routing line names the entry or the first-request resolve" grep -qE "Sandbox|first request resolves" "$WORK/stderr"
check "Edge persisted the script cache" grep -q "px_sandbox" "$CONFIG/script-cache.json"
if grep -q "^OPENCODE_SERVER_PASSWORD=" "$RECORD.env"; then
  fail "OPENCODE_SERVER_PASSWORD was removed from the child"
else
  pass "OPENCODE_SERVER_PASSWORD was removed from the child"
fi
EDGE_PID_1="$(edge_pid)"
PROXY_URL_1="$(grep -x "HTTP_PROXY=.*" "$RECORD.env" | head -1)"

echo "== scenario 2: warm second launch stays sticky without re-resolving =="
COUNT_BEFORE="$(provider_count)"
rm -f "$RECORD.args" "$RECORD.proxy"
run_launcher hello2
check "stub ran again" grep -q "^hello2$" "$RECORD.args"
check "stub reached the proxy successfully" grep -q "^200$" "$RECORD.proxy"
check "provider was not called again" test "$(provider_count)" -eq "$COUNT_BEFORE"
check "traffic went through proxy A again" test "$(grep -c relaydock.test "$PROXY_LOG_A")" -ge 2
check "routing line now names the warm upstream" grep -q "Sandbox (" "$WORK/stderr"
check "the tunnel carries best-effort peer attribution" bash -c "'$EDGE' status | grep -q 'peerName.*curl'"
check "the proxy URL is identical across launches" test "$(grep -x 'HTTP_PROXY=.*' "$RECORD.env" | head -1)" = "$PROXY_URL_1"
check "Edge is the same process (no restart)" test "$(edge_pid)" = "$EDGE_PID_1"

echo "== scenario 3: upstream rotation happens live, with no process restart =="
kill "$PROXY_A_PID" 2>/dev/null || true
wait "$PROXY_A_PID" 2>/dev/null || true
PROXY_A_PID=""
COUNT_BEFORE="$(provider_count)"
rm -f "$RECORD.args" "$RECORD.proxy"
run_launcher rotate
check "stub still reached a proxy successfully" grep -q "^200$" "$RECORD.proxy"
check "Edge re-ran the script after the dial failure" test "$(provider_count)" -gt "$COUNT_BEFORE"
check "traffic moved to the replacement upstream (proxy B)" grep -q "relaydock.test" "$PROXY_LOG_B"
check "Edge was not restarted for the rotation" test "$(edge_pid)" = "$EDGE_PID_1"
check "the proxy URL in the child env never changed" test "$(grep -x 'HTTP_PROXY=.*' "$RECORD.env" | head -1)" = "$PROXY_URL_1"

echo "== scenario 4: editing the script invalidates the cached resolution =="
EDGE_PID_BEFORE="$(edge_pid)"
COUNT_BEFORE="$(provider_count)"
write_store auto "// edited
$CACHING_SCRIPT"
rm -f "$RECORD.args" "$RECORD.proxy"
run_launcher after-edit
check "stub ran with the edited script" grep -q "^after-edit$" "$RECORD.args"
check "stub reached a proxy successfully" grep -q "^200$" "$RECORD.proxy"
check "the edited script re-ran the provider" test "$(provider_count)" -gt "$COUNT_BEFORE"
check "Edge stayed up across the edit" test "$(edge_pid)" = "$EDGE_PID_BEFORE"

echo "== scenario 5: the token gate covers proxy and admin paths =="
check "wrong proxy token gets 407" test "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -x "http://wrong-token@127.0.0.1:$EDGE_PORT" http://relaydock.test/x)" = "407"
check "missing admin token gets 401" test "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$EDGE_PORT/__relaydock/status")" = "401"
check "wrong admin token gets 401" test "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -H "Authorization: Bearer wrong" "http://127.0.0.1:$EDGE_PORT/__relaydock/status")" = "401"
check "the real token can read status" test "$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -H "Authorization: Bearer $EDGE_TOKEN" "http://127.0.0.1:$EDGE_PORT/__relaydock/status")" = "200"
check "the real token can run checks" curl -s --max-time 30 -X POST -H "Authorization: Bearer $EDGE_TOKEN" "http://127.0.0.1:$EDGE_PORT/__relaydock/check?scope=all" | grep -q '"results"'

echo "== scenario 6: Off mode launches without a proxy and never contacts Edge =="
edge_stop
rm -f "$CONFIG/edge.log"
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
if [[ -f "$CONFIG/edge.log" ]]; then
  fail "Off mode never contacts Edge"
else
  pass "Off mode never contacts Edge"
fi

echo "== scenario 7: missing edge.json fails closed with a reinstall hint =="
write_store auto "$CACHING_SCRIPT"
mv "$CONFIG/edge.json" "$CONFIG/edge.json.hidden"
rm -f "$RECORD.args"
set +e
run_launcher should-not-run
STATUS=$?
set -e
mv "$CONFIG/edge.json.hidden" "$CONFIG/edge.json"
check "launcher exited non-zero" test "$STATUS" -ne 0
if [[ -f "$RECORD.args" ]]; then
  fail "stub did not run without edge.json"
else
  pass "stub did not run without edge.json"
fi
check "stderr explains the failure and the fix" grep -q "opencode-wrapper.sh install" "$WORK/stderr"
check "stderr never promises a direct launch" grep -q "was not started" "$WORK/stderr"

echo "== scenario 8: a foreign port occupant fails closed loudly =="
edge_stop
python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $EDGE_PORT))
s.listen(1)
time.sleep(60)
" &
OCCUPANT_PID=$!
sleep 0.3
rm -f "$RECORD.args" "$CONFIG/edge.log"
set +e
run_launcher conflict
STATUS=$?
set -e
kill "$OCCUPANT_PID" 2>/dev/null || true
wait "$OCCUPANT_PID" 2>/dev/null || true
OCCUPANT_PID=""
check "launcher exited non-zero" test "$STATUS" -ne 0
if [[ -f "$RECORD.args" ]]; then
  fail "stub did not run against a foreign port occupant"
else
  pass "stub did not run against a foreign port occupant"
fi
check "stderr reports Edge never became ready" grep -q "did not become ready" "$WORK/stderr"
for _ in $(seq 1 25); do
  grep -q "not a compatible RelayDock Edge" "$CONFIG/edge.log" 2>/dev/null && break
  sleep 0.2
done
check "edge.log records the port conflict" grep -q "not a compatible RelayDock Edge" "$CONFIG/edge.log"

echo "== scenario 9: concurrent cold starts race safely (port bind is the mutex) =="
edge_stop
rm -f "$RECORD.args"
set +e
( run_launcher race-one ) &
RACE_ONE=$!
( run_launcher race-two ) &
RACE_TWO=$!
wait "$RACE_ONE"
STATUS_ONE=$?
wait "$RACE_TWO"
STATUS_TWO=$?
set -e
check "first racer succeeded" test "$STATUS_ONE" -eq 0
check "second racer succeeded" test "$STATUS_TWO" -eq 0
check "both stubs ran" bash -c "grep -q '^race-one$' '$RECORD.args' && grep -q '^race-two$' '$RECORD.args'"
check "exactly one Edge listener serves the port" test "$(lsof -nP -iTCP:"$EDGE_PORT" -sTCP:LISTEN -t 2>/dev/null | wc -l | tr -d ' ')" = "1"
check "stub traffic went through a proxy" test "$(grep -c relaydock.test "$PROXY_LOG_B")" -ge 1

echo "== scenario 10: a crashed Edge is respawned by the next launch =="
EDGE_PID_BEFORE="$(edge_pid)"
kill -9 "$EDGE_PID_BEFORE"
sleep 0.2
rm -f "$RECORD.args" "$RECORD.proxy"
run_launcher after-crash
check "stub ran after the crash" grep -q "^after-crash$" "$RECORD.args"
check "stub reached a proxy successfully" grep -q "^200$" "$RECORD.proxy"
EDGE_PID_AFTER="$(edge_pid)"
check "Edge is running again with a new pid" bash -c "test -n '$EDGE_PID_AFTER' && test '$EDGE_PID_AFTER' != '$EDGE_PID_BEFORE'"

echo "== scenario 11: RELAYDOCK_QUIET=1 silences the routing line =="
RELAYDOCK_QUIET=1
run_launcher quiet-run
unset RELAYDOCK_QUIET
check "stub still ran" grep -q "^quiet-run$" "$RECORD.args"
if [[ -s "$WORK/stderr" ]]; then
  fail "stderr is empty with RELAYDOCK_QUIET=1"
else
  pass "stderr is empty with RELAYDOCK_QUIET=1"
fi

echo "== scenario 12: the command replaces the launcher (terminal job control) =="
# A child in its own process group is SIGTTIN-stopped when a full-screen TUI
# reads the terminal. The launcher must exec the command instead, so the
# process (pid) and its foreground group survive.
RELAYDOCK_CONFIG_DIR="$CONFIG" bash -c 'set -m; "$1" sh -c "echo \$\$" > "$2/replace-child.pid" & JOB=$!; wait "$JOB"; echo "$JOB" > "$2/replace-job.pid"' _ "$LAUNCHER" "$WORK"
check "command runs as the launcher process (same pid)" test "$(cat "$WORK/replace-child.pid")" = "$(cat "$WORK/replace-job.pid")"
PTY_OUTPUT="$(RELAYDOCK_CONFIG_DIR="$CONFIG" PATH="$LINK_DIRECTORY:$STUB_DIRECTORY:/usr/bin:/bin:/usr/sbin:/sbin" \
  script -q /dev/null "$LAUNCHER" sh -c 'PG=$(ps -o pgid= -p $$ | tr -d " "); TP=$(ps -o tpgid= -p $$ | tr -d " "); if [ "$PG" = "$TP" ]; then echo FOREGROUND; else echo BACKGROUND; fi' 2>/dev/null | tr -d "\r")"
check "command keeps the terminal foreground group" grep -q FOREGROUND <<< "$PTY_OUTPUT"

echo "== scenario 13: the edge CLI reports and stops the daemon =="
if "$EDGE" status > /dev/null 2>&1; then
  pass "status exits zero while running"
else
  fail "status exits zero while running"
fi
check "status prints the pid" bash -c "'$EDGE' status | grep -q '\"pid\"'"
"$EDGE" stop > /dev/null
set +e
"$EDGE" status > /dev/null 2>&1
STATUS=$?
set -e
check "status exits non-zero after stop" test "$STATUS" -ne 0

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "All sandbox checks passed."
else
  echo "$FAILURES sandbox check(s) failed." >&2
  exit 1
fi
