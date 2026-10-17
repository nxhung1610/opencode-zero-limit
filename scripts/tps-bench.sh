#!/usr/bin/env bash
# RelayDock TPS A/B benchmark: OpenCode through Edge (wrapped) vs direct.
#
# Each round runs the same prompt twice — once via the installed wrapper (which
# routes through RelayDock Edge) and once via the real binary with every proxy
# variable stripped. Throughput is read back from OpenCode's database:
#
#     TPS = (tokens.output + tokens.reasoning) / Σ(time.streamed − time.created)
#
# summed over the run's assistant messages, so tool-call turns do not count
# their execution gaps as generation time. Prompt caching warms across runs; it
# moves first-token latency, not the generation rate this script reports.
#
# Requires the wrapper installed (scripts/opencode-wrapper.sh install), a
# running Edge (any wrapped launch spawns it), and an OpenCode v2 database at
# ~/.local/share/opencode/opencode.db (override: OPENCODE_DB).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
RUNS=3
RUN_TIMEOUT=240
PROMPT="Count from 1 to 120, one number per line. Output only the numbers."
WRAPPED_BIN=""
DIRECT_BIN=""
OUT_FILE=""

usage() {
  cat <<'USAGE'
Usage: scripts/tps-bench.sh [options]

  --runs N          runs per side (default 3, alternating order each round)
  --prompt TEXT     prompt sent to both sides
  --timeout SECONDS per-run wall-clock cap (default 240)
  --wrapped-bin P   binary for the Edge side (default: first 'opencode' on PATH)
  --direct-bin P    binary for the direct side (default: first non-wrapper 'opencode')
  --out FILE        also write the raw per-run results (TSV) to FILE

The wrapped side goes through RelayDock Edge; the direct side runs with
HTTP(S)_PROXY / ALL_PROXY stripped. TPS is read from the database rows the
run itself writes, never from wall-clock of the CLI.
USAGE
}

die() { echo "tps-bench: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --timeout) RUN_TIMEOUT="$2"; shift 2 ;;
    --wrapped-bin) WRAPPED_BIN="$2"; shift 2 ;;
    --direct-bin) DIRECT_BIN="$2"; shift 2 ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$RUNS" =~ ^[0-9]+$ ]] && (( RUNS >= 1 )) || die "--runs must be a positive integer"
[[ -f "$DB" ]] || die "OpenCode database not found at $DB (set OPENCODE_DB)"

realpath_of() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# --- pick the two binaries --------------------------------------------------

if [[ -z "$WRAPPED_BIN" ]]; then
  WRAPPED_BIN="$(command -v opencode || true)"
fi
[[ -n "$WRAPPED_BIN" ]] || die "no 'opencode' on PATH; install the wrapper or pass --wrapped-bin"
if [[ "$(basename "$(realpath_of "$WRAPPED_BIN")")" != "relaydock-launch" ]]; then
  echo "tps-bench: warning: $WRAPPED_BIN does not resolve to relaydock-launch." >&2
  echo "tps-bench:          The 'wrapped' side will NOT go through Edge." >&2
  echo "tps-bench:          Install first: $ROOT/scripts/opencode-wrapper.sh install" >&2
fi

if [[ -z "$DIRECT_BIN" ]]; then
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    case "$(realpath_of "$candidate")" in
      *relaydock*) continue ;;
    esac
    DIRECT_BIN="$candidate"
    break
  done < <(which -a opencode 2>/dev/null || true)
fi
[[ -n "$DIRECT_BIN" ]] || die "no non-wrapper 'opencode' found; pass --direct-bin PATH"

PROXY_VARS=(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy)
ENV_STRIP=()
for name in "${PROXY_VARS[@]}"; do ENV_STRIP+=(-u "$name"); done

# --- workdir + database reader ----------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relaydock-tps.XXXXXX")"
RESULTS="$WORK/results.tsv"
: > "$RESULTS"

cat > "$WORK/dbq.py" <<'PYEOF'
import json, os, sqlite3, sys, time

con = sqlite3.connect(f"file:{os.environ['TPS_BENCH_DB']}?mode=ro", uri=True)
command = sys.argv[1]

if command == "latest-session":
    since_ms = int(sys.argv[2])
    row = con.execute(
        "SELECT id FROM session_v2 WHERE parent_id IS NULL AND time_created >= ?"
        " ORDER BY time_created DESC LIMIT 1",
        (since_ms,),
    ).fetchone()
    print(row[0] if row else "")
elif command == "wait":
    sid, deadline = sys.argv[2], time.time() + float(sys.argv[3])
    while time.time() < deadline:
        count = con.execute(
            "SELECT COUNT(*) FROM session_message WHERE session_id = ?"
            " AND type = 'assistant' AND data LIKE '%tokens%'",
            (sid,),
        ).fetchone()[0]
        if count > 0:
            sys.exit(0)
        time.sleep(0.5)
    sys.exit(1)
elif command == "session":
    sid = sys.argv[2]
    output = reasoning = messages = 0
    seconds = 0.0
    model = ""
    for (data,) in con.execute(
        "SELECT data FROM session_message WHERE session_id = ? AND type = 'assistant'",
        (sid,),
    ):
        payload = json.loads(data)
        tokens = payload.get("tokens") or {}
        timing = payload.get("time") or {}
        out = int(tokens.get("output") or 0)
        rea = int(tokens.get("reasoning") or 0)
        created = timing.get("created")
        streamed = timing.get("streamed")
        if out + rea <= 0 or created is None or streamed is None or streamed <= created:
            continue
        output += out
        reasoning += rea
        seconds += (streamed - created) / 1000.0
        messages += 1
        model = model or (payload.get("model") or {}).get("id", "")
    tps = round((output + reasoning) / seconds, 2) if seconds > 0 else 0.0
    print(json.dumps({
        "session": sid, "messages": messages, "model": model,
        "output": output, "reasoning": reasoning,
        "streamSeconds": round(seconds, 3), "tps": tps,
    }))
else:
    sys.exit(2)
PYEOF

run_timed() { # timeout_seconds command...
  local secs="$1"
  shift
  python3 - "$secs" "$@" <<'PYEOF'
import subprocess, sys
timeout = float(sys.argv[1])
try:
    sys.exit(subprocess.run(sys.argv[2:]).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PYEOF
}

run_one() { # mode round
  local mode="$1" round="$2"
  local log="$WORK/run-${mode}-${round}.log"
  local started_ms sid rc=0 json
  started_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  printf '  [%s/%s] %-7s ... ' "$round" "$RUNS" "$mode"
  if [[ "$mode" == wrapped ]]; then
    run_timed "$RUN_TIMEOUT" "$WRAPPED_BIN" run --standalone "$PROMPT" >"$log" 2>&1 || rc=$?
  else
    run_timed "$RUN_TIMEOUT" env "${ENV_STRIP[@]}" "$DIRECT_BIN" run --standalone "$PROMPT" >"$log" 2>&1 || rc=$?
  fi
  sid=""
  for _ in $(seq 1 20); do
    sid="$(TPS_BENCH_DB="$DB" python3 "$WORK/dbq.py" latest-session "$started_ms")"
    if [[ -n "$sid" ]]; then break; fi
    sleep 0.5
  done
  if [[ -z "$sid" ]]; then
    echo "no session recorded (rc=$rc; log: $log)"
    return 0
  fi
  TPS_BENCH_DB="$DB" python3 "$WORK/dbq.py" wait "$sid" 30 >/dev/null || true
  json="$(TPS_BENCH_DB="$DB" python3 "$WORK/dbq.py" session "$sid")"
  python3 - "$json" "$mode" "$round" >>"$RESULTS" <<'PYEOF'
import json, sys
payload = json.loads(sys.argv[1])
print("\t".join([
    sys.argv[2], sys.argv[3], payload["session"], str(payload["messages"]),
    str(payload["output"]), str(payload["reasoning"]),
    str(payload["streamSeconds"]), str(payload["tps"]),
]))
PYEOF
  echo "rc=$rc $json"
}

# --- run ---------------------------------------------------------------------

echo "RelayDock TPS bench"
echo "  prompt    : $PROMPT"
echo "  rounds    : $RUNS per side (alternating order)"
echo "  wrapped   : $WRAPPED_BIN"
echo "  direct    : $DIRECT_BIN (proxy variables stripped)"
echo "  database  : $DB"
echo "  artifacts : $WORK"
echo

if command -v relaydock-edge >/dev/null 2>&1; then
  if ! relaydock-edge status >/dev/null 2>&1; then
    echo "tps-bench: warning: Edge does not answer 'relaydock-edge status'; the" >&2
    echo "tps-bench:          wrapped side will fail closed until Edge runs." >&2
  fi
fi

for ((round = 1; round <= RUNS; round++)); do
  if (( round % 2 == 1 )); then
    order=(wrapped direct)
  else
    order=(direct wrapped)
  fi
  for mode in "${order[@]}"; do
    run_one "$mode" "$round"
  done
done

python3 - "$RESULTS" <<'PYEOF'
import statistics, sys

rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    mode, round_number, sid, messages, output, reasoning, seconds, tps = line.split("\t")
    if int(messages) > 0 and float(tps) > 0:
        rows.append((mode, round_number, sid, int(output) + int(reasoning), float(seconds), float(tps)))

print()
print(f"{'mode':8} {'round':>5} {'tokens':>7} {'stream s':>9} {'TPS':>7}  session")
for mode, round_number, sid, tokens, seconds, tps in rows:
    print(f"{mode:8} {round_number:>5} {tokens:>7} {seconds:>9.1f} {tps:>7.2f}  {sid}")

medians = {}
for mode in ("wrapped", "direct"):
    values = [tps for row_mode, _, _, _, _, tps in rows if row_mode == mode]
    if values:
        medians[mode] = statistics.median(values)

print()
if len(medians) == 2:
    delta = (medians["wrapped"] - medians["direct"]) / medians["direct"] * 100.0
    print(f"median TPS - wrapped: {medians['wrapped']:.2f}   direct: {medians['direct']:.2f}   "
          f"wrapped vs direct: {delta:+.1f}%")
elif medians:
    (mode, value), = medians.items()
    print(f"median TPS - {mode}: {value:.2f} (the other side produced no usable samples)")
else:
    print("no usable samples; check the per-run logs in the artifacts directory")
PYEOF

if [[ -n "$OUT_FILE" ]]; then
  cp "$RESULTS" "$OUT_FILE"
  echo "results written to $OUT_FILE"
fi
echo "per-run logs: $WORK"
