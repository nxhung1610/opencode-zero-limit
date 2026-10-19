# RelayDock proxy system — design and as-built record

**Status:** implemented — P0, P1, P2a, P2, and P3 shipped (§7 is the phase ledger).

**Revision r4 (2026-10-18):** records P3 (optional upgrades) as built — launchd socket activation,
warm upstream sockets, and per-account listeners — and closes the §9 question on P3.

**Revision r3 (2026-10-18):** records P2 (app integration) as built — launchd KeepAlive agent,
launcher kickstart path, agent-aware `stop`, delegated health checks, the Edge status panel, and
the verification wording — and closes the §9 questions the implementation settled.

**Revision r2 (2026-10-17):** incorporates an adversarial review round. Changes: token-gated
identity (macOS exposes no usable TCP peer credentials — verified empirically), retry-on-dial
failover, single-writer state discipline, port/spawn-race contracts, and added P1 acceptance tests.

**Supersedes:** the spawn-time environment-injection model for the PATH wrapper
(`README.md` → “PATH wrapper for OpenCode”) and its cross-launch script cache.

**Scope:** macOS 14+, local-only, fail-closed. Covers the RelayDock app, `RelayDockCore`, the
PATH wrapper, and how OpenCode processes (CLI/TUI and the background service) reach the internet.

---

## 1. Why the current model needs a redesign

The current model resolves one proxy URL per launch and injects it as environment variables
(`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` + lowercase, merged `NO_PROXY`). Every fact below was
observed on a real machine, not hypothesized.

| # | Observed problem | Evidence |
|---|---|---|
| E1 | **The environment is fixed at process start.** The OpenCode background service (`opencode serve --service`) reads proxy variables once; changing the route requires `opencode service stop && opencode service start`, which interrupts running sessions. | Docker tripwire session; README §Service environment |
| E2 | **The resolved upstream endpoint dies roughly every 30 minutes.** The bestproxy script caches `lifetime − 60s` from the provider message (`"proxy nay se die sau 1777s"`), but long-lived processes (the service, a TUI left open) keep the dead endpoint until someone restarts them. | Live `proxies.json` script + `ProxyScriptRuntime` cache |
| E3 | **Three independent script caches** — the app (in-memory), the wrapper (disk), and implicit copies already baked into long-lived process environments — collide on the provider’s ~60 s `get.php` cooldown. A launch fetch at 15:39:52 followed by an app check at 15:40:42 recorded `Con 9s moi co the doi proxy` as a *failed health check*, which excluded the entry from Auto and fail-closed every subsequent launch until a manual re-test. | Live incident, 2026-10-17 |
| E4 | **The health model is too blunt and never self-heals.** Any script error (including a provider throttle that says nothing about the endpoint) marks a proxy failed; nothing re-checks periodically — recovery is a manual `Test` click. | `ProxyStore.checkEntry`, `ProxyStoreError.autoHasNoHealthyProxy` |
| E5 | **The wrapper carries duplicate machinery.** Disk cache file, script-hash guards, and its own resolution path must stay correct in a second process; the TUI hang (child in its own process group → SIGTTIN) showed the cost of a wrapper with its own process model. | `LauncherCacheFile.swift`, `Launcher.swift` |

All five problems share one root cause: **the routing decision happens where it cannot be
changed — inside each consumer process.** A redesign that keeps spawn-time injection will keep
re-encountering E1–E4.

## 2. Goals and non-goals

**Goals**

1. Rotation, upstream failover, and Off/Manual/Auto changes take effect **without restarting any
   OpenCode process** — including the background service.
2. **One owner** of script execution and caching; provider rate limits are handled in one place.
3. Health that **self-heals**: real connectivity failures mark failed with backoff re-checks;
   provider throttles defer, never mark failed.
4. Fail-closed stays: no silent direct routing when the policy cannot be satisfied. (One explicit,
   opt-in exception shipped later: the pool’s **Direct fallback** setting — labeled and counted,
   never silent; see §4.3 and §7.)
5. Keep the product stance: opt-in wrapper, manual service activation, no OpenCode lifecycle
   control, existing `proxies.json` path and permissions, `RELAYDOCK_CONFIG_DIR` honored.
6. Reduce, not add, moving parts per process: the wrapper becomes thin.

**Non-goals:** TLS interception/MITM, system-wide proxying (PAC, Network Extension, pf), cloud or
remote control, UI redesign, per-request exit-IP control at the edge (the provider already rotates
exit IPs server-side per request).

## 3. Architecture — RelayDock Edge

**Core idea:** every process that wants routing talks to a stable loopback endpoint. The
environment never changes; **RelayDock Edge**, a small local forwarding proxy, makes the route
decision per new connection. Rotation becomes invisible to consumers.

```
terminal ── opencode (env: HTTP_PROXY=http://<token>:@127.0.0.1:57211)
                  │ CONNECT
                  ▼
            RelayDock Edge  ── reads policy live ──  proxies.json (app writes)
            127.0.0.1:57211             │
                  ├── resolves via bestproxy script (single cache owner)
                  └── CONNECT/SOCKS upstream ── rotating proxy ── OpenCode API
opencode serve --service ── same stable env (activated once) ──┘
RelayDock app ── status + delegated checks + lifecycle ──► Edge
```

**Components**

| Component | What changes |
|---|---|
| **RelayDock Edge** (new executable, `relaydock-edge`) | Loopback HTTP proxy (`CONNECT` tunneling + absolute-URI forwarding), `http(s)`/`socks*` upstreams, live policy reads, rotation/failover, health scheduler, token-gated status API, libproc-based tunnel attribution, log. Reuses `RelayDockCore` (store + script runtime). No UI. |
| **`relaydock-launch`** (rewritten, thinner) | No script resolution, no disk cache, no endpoint in env. Reads `edge.json` → ensures Edge is running → prints the routing line from Edge status → `execve`s OpenCode with the **constant** proxy environment. Off mode: no proxy env at all (Off stays truly off). |
| **`RelayDockCore`** (mostly unchanged) | Keeps `selectForSpawn`/env helpers for library consumers; the wrapper stops using the script path. `ProxyScriptRuntime` gains the retry-after classification used by Edge. |
| **RelayDock app** (P2) | Shows Edge status (upstream, rotations, tunnels, service attribution), delegates script health checks to Edge, manages Edge lifecycle. Pool editing unchanged. |
| **State files** | `proxies.json` unchanged (app writes, Edge reads by mtime). New `edge.json` (port + token, written at install; read by wrapper/app). New Edge-owned script cache + `edge.log` (0600). |

**Route semantics stay recognizably “RelayDock”:** Manual/Auto keep the same fail-closed policy
(`selectForSpawn` semantics: enabled+valid+not-known-failed, sticky binding), just executed live
by Edge instead of at spawn time.

## 4. Edge policies (the interesting parts)

### 4.1 Selection and rotation

- Per **new** connection: if mode is Off → forward direct; if the current upstream is missing,
  expired, or suspect → resolve (single-flight, deduped) via the entry’s script or static URL.
- **Warm-up:** Edge resolves eagerly at startup and on mode/selection changes, so most terminal
  launches already have an upstream; the launcher’s routing line reports it (or says plainly that
  the first request will resolve).
- **Proactive refresh:** when the cached upstream is within `min(60 s, lifetime/10)` of its
  expiry, the next new connection triggers a resolve first. RelayDock never cuts a tunnel for
  rotation — but provider-side endpoint death (~30 min lifetime) can still drop a long-running
  stream mid-flight; the client retry then hits the refreshed upstream.
- **Rotation script (worked example):** the live 5-minute rotation script is mirrored, key
  removed, at `docs/templates/bestproxy-rotate-5m.js`. Its cache window is
  `min(5 min, provider lifetime − 60 s)` with a 30 s floor, so a resolve stays clear of the
  provider's ~60 s change cooldown and the exit IP re-resolves on roughly a 5-minute cadence
  instead of waiting out the endpoint's full lifetime.
- **Reactive failover:** a failed dial is a strong signal. Edge single-flight-resolves and retries
  the client’s connection once internally, so a dead endpoint usually becomes transparently
  slower instead of an error. Three consecutive failures (within 30 s) additionally mark the
  upstream suspect in status/health. If the resolve fails (throttle) but the old upstream still
  works, **keep using the old upstream** and show a warning; refuse (502 with reason) only when
  the old upstream is dead *and* no replacement resolved.
- Provider throttle (`Con Ns moi co the doi proxy` and similar) → parse `retryAfter`, schedule the
  next attempt, and **do not** record a failed health check.

### 4.2 Health

- Edge owns periodic checks for the active entry (default every 10 min) and backoff re-checks for
  entries with a failed last check (5 → 15 → 60 min cap); a success clears failure.
- Checks probe, they never resolve: a script entry is checked at the URL it is currently serving
  (the live upstream, a pinned upstream, or the resolution its script cache holds). Pressing
  `Test All` can therefore never rotate the exit or spend the provider’s change cooldown — that
  budget belongs to routing resolutions (launch, expiry, death recovery), not to checks. With
  nothing resolved yet there is nothing to dial: the check is **deferred** ("no resolved proxy
  yet") and the entry keeps its last health instead of borrowing a script error as a failure.
- Classification: TCP/TLS/HTTP failure through the proxy → **failed** (real connectivity fact);
  nothing to probe → **deferred** with `retryAt`; neither hijacks the other.
- A tunnel that dies mid-stream or stalls (request bytes flowed, no response byte for 30 s, the
  client gives up) schedules a near-term re-check (≤30 s) through a fresh endpoint, so a zombie
  provider cannot hide behind an open-but-silent tunnel.
- The app’s `Test All` delegates to `GET /__relaydock/check?scope=all` whenever `edge.json` exists
  and Edge answers; skipped (deferred) results are surfaced as a plain message, not recorded. The
  app falls back to its in-process path only when Edge is not configured or unreachable (degraded
  mode; the pool view says which route ran), and that path follows the same probe rule — a script
  entry with nothing resolved keeps its last health. Checks are diagnostics, not routing: Edge
  answers `/check` in Off mode too, while the periodic scheduler still skips Off.
- **Persistence discipline:** `proxies.json` stays single-writer (the app, always — P1 and beyond;
  Edge reports check results, the app persists them). Edge’s live health lives in Edge state and
  the status API; Auto eligibility uses that live view, not the file’s last snapshot. Reads
  tolerate a partially written file: decode failure keeps the last good config and never breaks
  live traffic.

### 4.3 Fail-closed matrix

| Situation | Behavior |
|---|---|
| Edge unreachable, wrapper installed | Launcher tries to start Edge (on-demand spawn; launchd kickstart when the agent exists), then refuses to exec with exit 1 + hint. Never “silently direct”. |
| Manual/Auto, no usable entry at resolve time | New CONNECTs → `502` + reason; existing tunnels continue; status lists the reason. With the pool’s opt-in **Direct fallback** enabled, new CONNECTs dial direct instead — the tunnel is labeled `direct (fallback)`, counted in `directFallbacks`, and logged; pinned listeners never take this path. |
| Resolve error reaches a wrapped terminal launch | Not blocked at launch: the TUI opens and the first request fails closed (502 + reason), or dials direct when the pool opts into Direct fallback. Deliberate — provider timing never blocks the terminal; warm-up makes this rare. |
| Mode switched to Off while processes hold Edge env | Edge forwards direct (transparent); fresh launches get no env at all. |
| Upstream dies mid-tunnel | Tunnel drops; the next dial re-resolves single-flight and is retried once internally; 502 only when nothing is usable (or a labeled direct fallback when the pool enables one). A death or zero-byte stall on an established tunnel also counts as a strike (first-ender classification: client-induced cancels never strike), drops the script snapshot, re-resolves immediately when a mode is active, and raises `streamFailures`. The dead request itself is never retried — bytes were already in flight. |
| Refusal inside a provider cooldown | The `502` carries `Retry-After: <whole seconds>` built from the pending `retryAt`; the absence of the header means "retry whenever". |
| Edge crash | The launchd KeepAlive agent restarts it within its throttle (`SuccessfulExit: false` — a clean loser-exit never respawn-loops); without the agent, the next launch/app contact respawns it. |
| Edge cannot bind its port | Edge exits loudly (boot error in `edge.log`); the launcher refuses with a port-conflict/reinstall hint. Ports never renumber silently once consumers hold the env. |
| Provider rate-limited during resolve | Serve old upstream; `retryAt` in status; health untouched. |

### 4.4 Status API and verification (the honesty upgrade)

- Identity is **token-based, not credential-based.** Verified empirically: macOS exposes no usable
  peer credentials for TCP (`LOCAL_PEERPID` is `ENOPROTOOPT`; `LOCAL_PEERCRED` returns success
  without writing the buffer; `LOCAL_PEEREPID` returns 0). The installer writes a random token to
  `edge.json`; the proxy env carries it as `http://<token>:@127.0.0.1:<port>` and admin
  endpoints require it as a header. The trailing colon is load-bearing: the Docker E2E verified
  against the real binary (opencode v2.0.30, Bun) that a `user:` userinfo yields
  `Proxy-Authorization: Basic base64("<token>:")`, while a bare `user@` userinfo makes its fetch
  never connect at all. The same binary honors `NO_PROXY` for `localhost`/`127.0.0.1`, so CLI↔service
  loopback traffic bypasses Edge (control run without `NO_PROXY` was routed through the proxy).
- `GET http://127.0.0.1:<port>/__relaydock/status` → JSON: mode, upstream (label, masked URL,
  source, resolved/expires at), rotation counters, backoff state, last errors, and active/recent
  tunnels with **peer-process attribution** via a libproc fd scan (same-user only, on demand,
  cached for a few seconds, best-effort — it never gates or slows routing). Same-user scope is
  exactly the trust domain we need; it is the mechanism `lsof` uses (verified working
  unprivileged on this machine).
- `POST /__relaydock/check` → `{entryID}` → runs one health check through Edge.
- Loopback-bind only, plus the token on every request. A future kernel-level hardening option is
  a `pf` rule matching the user (P3, needs root; not on the critical path).
- Because Edge sees real tunnels keyed by peer process, RelayDock can finally report
  **evidence** — e.g. “OpenCode service (pid) tunneled 12 connections via BestProxy xoay, last
  2 min ago”. **Shipped wording (r3):** “RelayDock verifies traffic that routes through Edge;
  direct traffic stays invisible.” — used in the app footer, menu bar panel, installer hint, and
  docs. The Routing tab’s Edge section and the menu bar’s Edge line render this evidence live
  from `/__relaydock/status` (polled while a surface is visible; a miss reads as “not running”,
  never as an error).

## 5. Files, ports, lifecycle

- **Default port `57211`** on `127.0.0.1`; installer probes for a free port, writes
  `<config>/edge.json` (`{version, port, token}`); wrapper and app read it. Consumers never guess.
  The port is **immutable once consumers hold it**: if Edge cannot bind at runtime it exits loudly
  (boot error in `edge.log`) and the launcher refuses with a port-conflict/reinstall hint. Silent
  renumbering is forbidden — it would strand the service’s env.
- **Lifecycle (P1):** spawn-on-demand. The wrapper (or app) starts `relaydock-edge` detached when
  status ping fails; Edge stays resident while the user is logged in (it must outlive prompts of
  the long-running service). Concurrent spawns are safe: the port bind is the mutex, and a loser
  verifies the winner is healthy and exits silently (no error noise). P3 binds the listener with
  `SO_REUSEADDR`, so a restart can rebind while the previous incarnation’s connections drain
  through `TIME_WAIT`; a bound, live listener still conflicts, so the mutex holds.
- **KeepAlive (P2, shipped):** the installer writes
  `~/Library/LaunchAgents/com.nxhung.relaydock.edge.plist` — generated by
  `relaydock-edge agent-plist`, so the plist and the binary agree on one label — and bootstraps
  it. The job bakes `RELAYDOCK_CONFIG_DIR`; a baked config dir scopes the agent, so a plist for
  another config dir never boots out the login-session agent. `RunAtLoad` +
  `KeepAlive { SuccessfulExit: false }`: a crash restarts within the 15 s throttle, while a clean
  quiet-exit loser (exit 0) does not respawn-loop. The launcher kickstarts a loaded agent (or
  bootstraps an unloaded one) before falling back to spawning the binary; `relaydock-edge stop`
  boots the managing agent out when one manages this config dir, else asks the daemon to exit.
  When `<config>/edge.json` exists the plist additionally declares `Sockets` (loopback stream/TCP)
  and drops `RunAtLoad`: launchd owns the listener and starts Edge on the first connection (P3,
  §7). App-side `SMAppService` remains gated on signing.
- **Script cache:** Edge-owned `<config>/script-cache.json` (existing snapshot format/API); one-time
  import of the legacy `launcher-cache.json` if present. No other process reads or writes it.
- **service activation** stays manual and one-time: after installing (or if the service currently
  runs without the Edge env), run `opencode service stop && opencode service start` from a wrapped
  shell once — or reboot. After that, rotations and mode changes **never** require another restart;
  a cold-started service inherits the wrapper env automatically.
- **Uninstall / rollback:** the wrapper script or the app's *Routing setup* card removes the symlink,
  `relaydock-edge`, `relaydock-launch`, `edge.json`, and the agent (if any); `proxies.json` and Edge
  cache remain user data unless explicitly cleared. Removing the wrapper returns launches to direct;
  the previous spawn-time launcher can be rebuilt from git and reinstalled as a downgrade path.

## 6. What consumers see

| Consumer | Before | After |
|---|---|---|
| Terminal `opencode` launch | per-launch resolved endpoint in env; dies in ~30 min | constant env; routing line reports mode + warmed upstream (or “resolves on first request”); no launch ever blocks on provider timing |
| `opencode serve --service` | env freezes an endpoint for days; stop+start per rotation | activated once; survives rotations; visible in status with tunnel attribution |
| RelayDock app Test | resolves scripts itself → rate-limit collisions | P1: shares Edge’s script cache around checks; P2: fully delegated to Edge (`/check`), which probes the current resolution and never runs the script — Test All cannot rotate or trip the provider cooldown; nothing to probe is `deferred`, never failed |
| Library consumers (`RelayDockCore`) | unchanged API (`selectForSpawn`, env helpers) | unchanged; Edge is the new first-party implementation of that pattern |

## 7. Migration phases

- **P0 (done):** wrapper `execve` fix — terminal job control (PR #8).
- **P1 — Edge core:** `relaydock-edge` target (proxy engine, rotation/failover with retry-on-dial,
  health scheduler, token-gated status API, libproc attribution, log), wrapper rewrite (constant
  env, ensure-Edge, status line), installer updates, app shares Edge’s script cache around
  `checkAll()`, README/PRODUCT updates. Retires `LauncherCacheFile`.
  Acceptance tests: hermetic rotation without process restart; token header actually arrives from
  the real binary; TUI↔service localhost traffic under the Edge env (`NO_PROXY` with Bun — never
  yet exercised end-to-end); one-time service activation followed by rotation with no restarts.
- **P2a — Edge stability (implemented):** relay-end classification (first-ender wins; client-induced
  cancels never strike), `noteTunnelFailure` (strike + snapshot drop + single-flight re-resolve +
  near-term health re-check), `Retry-After` on 502s issued during a provider cooldown, and a
  `streamFailures` counter (additive field; older binaries still decode). Tests: unit suite plus
  hermetic sandbox scenarios (mid-stream death, zero-byte stall, cooldown); `scripts/tps-bench.sh`
  measures wrapped-vs-direct TPS read back from the OpenCode database.
- **P2 — App integration (implemented):** launchd KeepAlive agent, launcher kickstart path, and
  agent-aware `stop` (§5); `Test All` delegating to Edge’s `/check?scope=all` with a labeled
  in-process fallback; Routing tab Edge panel (mode, upstream + expiry, counters, cooldown, last
  error, tunnel attribution grouped by peer process) polled from `/status` while a
  window/popover is visible; menu bar Edge line; the honesty wording shipped across app, menu
  bar, installer hint, and docs; sandbox scenarios for agent wiring, kickstart, and
  bootout-on-stop.
- **P3 — Optional (implemented):** three upgrades, all behind the same consumer contracts.
  *Socket activation:* when `<config>/edge.json` exists the installer’s plist declares `Sockets`
  (IPv4 loopback, stream/TCP) and `RunAtLoad false`, so launchd owns the listener and starts Edge
  on the first connection; Edge retrieves the inherited descriptor with `launch_activate_socket`,
  and the launcher first waits a short wake window before falling back to kickstart/spawn (plists
  without `Sockets` keep the P2 `RunAtLoad` behavior). The inherited descriptor and self-bound
  listeners share one blocking `accept` loop. No idle self-exit: launchd keeps the socket, Edge
  keeps its state.
  *Upstream pooling (safe subset):* after a successful dial Edge stores one pre-dialed,
  un-handshaken TCP/TLS socket to the proxy (depth 1, 20 s lifetime, keyed by scheme+host+port —
  never credentials), offers it to the first dial attempt of the next resolution, drains it on
  upstream switch, and never reuses a socket twice. Warm sockets are reused only on paths with a
  handshake (CONNECT / SOCKS), where staleness surfaces as a dial failure the retry contract
  already handles; plain http/https forwards always dial cold, because there a stale socket would
  break mid-request instead. True post-relay keep-alive reuse stays future work — relay
  cancellation closes both halves today.
  *Per-account listeners:* `edge.json` gains an optional `listeners: [{port, entryID}]`; each extra
  loopback port is pinned to one pool entry (global Off mode does not apply — an explicit binding
  never falls back to direct), resolves through the same single-flight + strike machinery, and
  `/status` reports `listeners: [{port, entryID?, activated}]`. A pinned listener that cannot bind
  warns and steps aside; only the primary port owns the loud boot failure. Old binaries and config
  files decode the new fields tolerantly. Tests: unit suites plus sandbox scenarios for the
  activated serve path and a pinned listener.

- **P3.1 — Opt-in Direct fallback (implemented):** `ProxyState` gains `directFallback` (default
  off, decoded tolerantly). When enabled, a route decision with no usable upstream answers
  `.directFallback` instead of `.refuse`, and the connection handler dials the target directly
  with tunnel label `direct (fallback)` — also counted in the additive `directFallbacks` status
  counter and logged. Dial-retry exhaustion takes the same path, except for pinned listeners,
  which always fail closed. Fail-closed remains the default; the launcher never routes direct on
  its own. The Routing tab shows the toggle (Manual/Auto), and the shared consequence line reads
  the setting.
- **P4 — App-driven routing setup (implemented):** the app bundle carries `relaydock-launch` and
  `relaydock-edge` in `Contents/Resources` (named so the installer's default sibling launcher
  resolves inside the bundle; a SHA-256 comparison against the installed copies drives the drift
  check), and `relaydock-edge` gains `install`/`uninstall` subcommands so app and script share one
  installer. The Routing tab grows a *Routing setup* card: **Install Routing** runs the bundled
  installer (same code path as the script — one installer, two frontends), **Update Components**
  appears when the installed pair differs from this build, **Verify** asks the user's login shell
  (`zsh -lic 'command -v opencode'`) and distinguishes "resolves to the wrapper" from a missing or
  shadowed command (the PATH snippet is copyable text; the app never edits `~/.zshrc` or
  `~/.zprofile`), and **Uninstall…** sits behind a confirmation that lists exactly what is removed
  (agent, both binaries, symlink, `edge.json`) while the proxy pool and Edge's script cache stay.
  Nothing runs unprompted, and the app still never launches or restarts OpenCode — the
  `opencode service stop && opencode service start` hint is copyable text.

## 8. Alternatives considered

| Alternative | Why not |
|---|---|
| Keep spawn-time injection, document “relaunch/restart to rotate” | E1/E2 are unfixable by policy: long-lived processes cannot pick up a new env, and the service restart interrupts sessions. |
| App-hosted listener (no separate process) | Routing lifetime would be coupled to the menubar app; quitting the app would break the service’s connections until relaunch. Edge as its own process keeps app and routing lifecycles independent. |
| Edge with idle self-exit | The background service must reach Edge between prompts, hours apart; self-exit would break it. Residency is a requirement, not a luxury. |
| launchd socket activation from day one | Genuinely elegant, but adds launchd packaging complexity to the critical path; deferred to P3 without changing consumer contracts. |
| PAC / Network Extension / transparent interception | System-wide blast radius, entitlements/signing burden, and TLS MITM — all out of product scope. |
| Configure proxy inside OpenCode’s own config instead of env | No documented, stable interface for it; env proxying is the mechanism already proven end-to-end (Docker E2E against the real binary). |

## 9. Questions and resolutions

1. ~~Product wording for the verification upgrade in §4.4~~ **Resolved in r3 (P2):** shipped as
   “RelayDock verifies traffic that routes through Edge; direct traffic stays invisible.”
2. ~~Status API hardening via TCP peer credentials~~ **Resolved in r2:** unusable on macOS
   (verified); replaced by the per-install token gate (§4.4).
3. ~~Port policy~~ **Resolved in P1:** fixed default `57211` with installer probing and the
   immutable-once-consumed contract (§5); no derivation scheme.
4. ~~Edge ownership of periodic health checks~~ **Resolved in P2a/P2:** 10-minute cadence with
   backoff re-checks, plus near-term re-checks after mid-stream failures (§4.2).
5. ~~P1 lifecycle~~ **Resolved in P2:** spawn-on-demand in P1; the launchd agent shipped in P2 (§5).
6. ~~Whether socket activation, upstream pooling, and per-account ports are worth building~~
   **Resolved in r4 (P3):** all three shipped, with pooling scoped to the safe subset (see §7).
