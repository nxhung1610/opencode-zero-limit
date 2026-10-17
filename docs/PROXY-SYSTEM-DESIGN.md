# RelayDock proxy system — design proposal

**Status:** Proposal — not implemented. Review and approval required before scheduling work.

**Revision r2 (2026-10-17):** incorporates an adversarial review round. Changes: token-gated
identity (macOS exposes no usable TCP peer credentials — verified empirically), retry-on-dial
failover, single-writer state discipline, port/spawn-race contracts, and added P1 acceptance tests.

**Supersedes, on acceptance:** the spawn-time environment-injection model for the PATH wrapper
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
4. Fail-closed stays: no silent direct routing when the policy cannot be satisfied.
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
- Classification: TCP/TLS/HTTP failure through the proxy → **failed** (real connectivity fact);
  script error / provider throttle → **deferred** with `retryAt`; neither hijacks the other.
- A tunnel that dies mid-stream or stalls (request bytes flowed, no response byte for 30 s, the
  client gives up) schedules a near-term re-check (≤30 s) through a fresh endpoint, so a zombie
  provider cannot hide behind an open-but-silent tunnel.
- The app’s `Test`/`Check All` delegates to `POST /__relaydock/check`; the app falls back to its
  in-process path only when Edge is not running (degraded mode, warned in UI).
- **Persistence discipline:** `proxies.json` stays single-writer (the app, always — P1 and beyond;
  Edge reports check results, the app persists them). Edge’s live health lives in Edge state and
  the status API; Auto eligibility uses that live view, not the file’s last snapshot. Reads
  tolerate a partially written file: decode failure keeps the last good config and never breaks
  live traffic.

### 4.3 Fail-closed matrix

| Situation | Behavior |
|---|---|
| Edge unreachable, wrapper installed | Launcher tries to start Edge (on-demand spawn; launchd kickstart when the agent exists), then refuses to exec with exit 1 + hint. Never “silently direct”. |
| Manual/Auto, no usable entry at resolve time | New CONNECTs → `502` + reason; existing tunnels continue; status lists the reason. |
| Resolve error reaches a wrapped terminal launch | Not blocked at launch: the TUI opens and the first request fails closed (502 + reason). Deliberate — provider timing never blocks the terminal; warm-up makes this rare. |
| Mode switched to Off while processes hold Edge env | Edge forwards direct (transparent); fresh launches get no env at all. |
| Upstream dies mid-tunnel | Tunnel drops; the next dial re-resolves single-flight and is retried once internally; 502 only when nothing is usable. A death or zero-byte stall on an established tunnel also counts as a strike (first-ender classification: client-induced cancels never strike), drops the script snapshot, re-resolves immediately when a mode is active, and raises `streamFailures`. The dead request itself is never retried — bytes were already in flight. |
| Refusal inside a provider cooldown | The `502` carries `Retry-After: <whole seconds>` built from the pending `retryAt`; the absence of the header means "retry whenever". |
| Edge crash | Capability lost until next launch/app contact respawns it; P2 adds a launchd KeepAlive agent to shrink the window. |
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
  2 min ago”. The project’s honesty line evolves from “cannot verify traffic” to “verifies
  Edge-routed traffic only; direct traffic stays invisible.” Wording change is a product
  decision tracked in §9.

## 5. Files, ports, lifecycle

- **Default port `57211`** on `127.0.0.1`; installer probes for a free port, writes
  `<config>/edge.json` (`{version, port, token}`); wrapper and app read it. Consumers never guess.
  The port is **immutable once consumers hold it**: if Edge cannot bind at runtime it exits loudly
  (boot error in `edge.log`) and the launcher refuses with a port-conflict/reinstall hint. Silent
  renumbering is forbidden — it would strand the service’s env.
- **Lifecycle (P1):** spawn-on-demand. The wrapper (or app) starts `relaydock-edge` detached when
  status ping fails; Edge stays resident while the user is logged in (it must outlive prompts of
  the long-running service). Concurrent spawns are safe: the port bind is the mutex, and a loser
  verifies the winner is healthy and exits silently (no error noise).
- **KeepAlive (P2):** a login-shell `launchd` agent; the app ships it via `SMAppService` once the
  app is signed — unsigned/CLI-only installs use the installer-provided plist (the supported path
  for local builds today).
- **Script cache:** Edge-owned `<config>/script-cache.json` (existing snapshot format/API); one-time
  import of the legacy `launcher-cache.json` if present. No other process reads or writes it.
- **service activation** stays manual and one-time: after installing (or if the service currently
  runs without the Edge env), run `opencode service stop && opencode service start` from a wrapped
  shell once — or reboot. After that, rotations and mode changes **never** require another restart;
  a cold-started service inherits the wrapper env automatically.
- **Uninstall / rollback:** wrapper script removes symlink, `relaydock-edge`, `edge.json`, agent
  (if any); `proxies.json` and Edge cache remain user data unless explicitly cleared. Removing the
  wrapper returns launches to direct; the previous spawn-time launcher can be rebuilt from git and
  reinstalled as a downgrade path.

## 6. What consumers see

| Consumer | Before | After |
|---|---|---|
| Terminal `opencode` launch | per-launch resolved endpoint in env; dies in ~30 min | constant env; routing line reports mode + warmed upstream (or “resolves on first request”); no launch ever blocks on provider timing |
| `opencode serve --service` | env freezes an endpoint for days; stop+start per rotation | activated once; survives rotations; visible in status with tunnel attribution |
| RelayDock app Test | resolves scripts itself → rate-limit collisions | P1: shares Edge’s script cache around checks; P2: fully delegated to Edge (`/check`); throttles are `deferred`, not failed |
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
- **P2 — App integration:** status panel, delegated checks, Edge lifecycle (KeepAlive agent;
  `SMAppService` needs a signed app, installer plist until then), service attribution UI, product
  wording for verified-edge-traffic.
- **P3 — Optional:** launchd socket activation (Edge starts on first connection), upstream
  connection pooling, per-account ports for multi-binding use.

## 8. Alternatives considered

| Alternative | Why not |
|---|---|
| Keep spawn-time injection, document “relaunch/restart to rotate” | E1/E2 are unfixable by policy: long-lived processes cannot pick up a new env, and the service restart interrupts sessions. |
| App-hosted listener (no separate process) | Routing lifetime would be coupled to the menubar app; quitting the app would break the service’s connections until relaunch. Edge as its own process keeps app and routing lifecycles independent. |
| Edge with idle self-exit | The background service must reach Edge between prompts, hours apart; self-exit would break it. Residency is a requirement, not a luxury. |
| launchd socket activation from day one | Genuinely elegant, but adds launchd packaging complexity to the critical path; deferred to P3 without changing consumer contracts. |
| PAC / Network Extension / transparent interception | System-wide blast radius, entitlements/signing burden, and TLS MITM — all out of product scope. |
| Configure proxy inside OpenCode’s own config instead of env | No documented, stable interface for it; env proxying is the mechanism already proven end-to-end (Docker E2E against the real binary). |

## 9. Open questions (need answers before P1 closes)

1. Product wording for the verification upgrade in §4.4 — update `PRODUCT.md`/README honesty text in
   the same change as the app status panel, or keep current wording until P2 ships?
2. ~~Status API hardening via TCP peer credentials~~ **Resolved in r2:** unusable on macOS
   (verified); replaced by the per-install token gate (§4.4).
3. Port policy: fixed default `57211` with installer probing — acceptable, or prefer a
   deterministic derivation (e.g. hash of home path) to avoid cross-machine drift in docs?
4. Edge ownership of periodic health checks: default cadence 10 min OK against the provider’s
   cooldowns, or derive from `retryAfter`/lifetime only (no fixed timer)?
5. P1 lifecycle: spawn-on-demand only (recommended) or ship the launchd agent in P1 too?
