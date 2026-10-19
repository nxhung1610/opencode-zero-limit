# RelayDock for macOS

RelayDock is a compact native SwiftUI utility for managing a local proxy pool and its Off/Manual/Auto policy. It can import proxies, test enabled endpoints, and — with the optional PATH wrapper (see [PATH wrapper for OpenCode](#path-wrapper-for-opencode)) — show what **RelayDock Edge**, a small loopback daemon, is actually doing: the live upstream, rotation counters, and per-process tunnel attribution for everything routed through it. The app does **not** launch or restart OpenCode, and Edge verifies only the traffic that routes through it; direct traffic stays invisible.

**Platform:** macOS 14 or later. **Language:** Swift 6.

## What it provides

- Import and persist HTTP, HTTPS, SOCKS4, SOCKS4A, SOCKS5, and SOCKS5H proxy URLs — one at a time or in bulk.
- Support named custom JavaScript entries that resolve to a proxy each time a consumer launches a child process.
- Enable, disable, remove, and health-check proxies in the local pool.
- Save Off, Manual, or Auto policy. Manual and Auto configuration remains fail-closed; invalid or missing routes are not silently changed to Off.
- Preserve existing proxy data at `~/Library/Application Support/com.nxhung.opencodezerolimit/proxies.json` with restrictive file permissions.
- Provide `RelayDockCore` helpers for consumers that launch their own child process and need to select a route and construct proxy environment variables.
- Optionally install a PATH wrapper (`scripts/opencode-wrapper.sh install`) so new terminal `opencode` launches run through **RelayDock Edge**: a loopback daemon that performs script resolution live, rotates the upstream when a dial fails, keeps one provider cooldown budget, and persists one script cache. The installer also bootstraps a launchd KeepAlive agent (crash restarts within seconds; clean exits never respawn-loop; with an `edge.json` present the agent also declares launchd `Sockets`, so Edge starts on the first connection). Fail-closed on routing errors; Off mode never contacts Edge.
- Show Edge's live status in the app: a RelayDock Edge section on the Routing tab and a compact line in the menu bar popover — mode, upstream with expiry, rotation/failure counters, provider cooldown, and recent tunnels attributed to the peer process that opened them. `Test All` delegates health checks to Edge (the owner of the script cache) and falls back in-process, labeled in the pool view, only when Edge is unreachable.

A successful endpoint check only reports that the configured proxy endpoint passed that check. Neither a saved policy nor a successful check proves that OpenCode traffic used a proxy — only Edge's tunnel accounting speaks to real traffic, and it says nothing about traffic that bypasses Edge: **RelayDock verifies traffic that routes through Edge; direct traffic stays invisible.**

## Build, test, and run

Requires macOS 14+ and Swift 6:

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
scripts/build-dmg.sh              # RelayDock.app → build/RelayDock.dmg (drag-to-Applications image)
open build/RelayDock.app
scripts/build-launcher.sh         # PATH wrapper + Edge daemon binaries → build/relaydock-launch, build/relaydock-edge
scripts/launcher-sandbox-test.sh  # hermetic end-to-end: stub command, fake provider/proxies, real launcher + Edge
scripts/tps-bench.sh              # A/B TPS: wrapped (via Edge) vs direct, read back from OpenCode's database
```

The app is currently unsigned and not notarized for public distribution.

## Continuous delivery

`ci.yml` tests every pull request and push to `main` (test suite + app bundle validation).
`cd.yml` packages the same commits into downloadable build artifacts: `RelayDock.dmg` (plus the
bundled `RelayDock.app.zip`), the `relaydock-edge` and `relaydock-launch` binaries, and a
`SHA256SUMS` file — as a workflow artifact (30 days) on every run. Pushing a `v*` tag additionally
publishes the same files as a GitHub Release. Packaged builds are unsigned, exactly like local
`scripts/build-*.sh` ones.

## Core library

Add the `macOS/RelayDock` Swift package and import `RelayDockCore` from a process-launching consumer:

```swift
import RelayDockCore

let proxies = ProxyStore()
// Optional: carry script caches across launches of a fresh consumer process.
importProxyScriptCacheSnapshots(try readSnapshotsFromDisk())
let selectedProxyURL = try proxies.selectForSpawn()
let childEnvironment = buildOpenCodeProxyEnvironment(proxyURL: selectedProxyURL)
try writeSnapshotsToDisk(exportProxyScriptCacheSnapshots())
```

`exportProxyScriptCacheSnapshots()` / `importProxyScriptCacheSnapshots(_:)` carry each entry's in-memory script `cache` across process launches: import before `selectForSpawn()`, export after it, and store the map wherever your consumer keeps state. Import skips entries that are not JSON objects or exceed the 64 KB cache limit.

`selectForSpawn()` returns `nil` only for explicit Off mode. Do not catch a Manual/Auto selection error and continue with `nil`; surface the error and do not launch the child process. Auto may use enabled proxies whose health is unknown, but excludes proxies whose last recorded check failed. When the selection is a custom JavaScript entry, `selectForSpawn()` runs the script first; a script error, timeout, or invalid result is thrown so the launch stays fail-closed. The consumer must actually use the returned environment when launching the child and must independently verify its HTTP client's behavior. (The PATH wrapper below no longer calls `selectForSpawn()` itself — it delegates to RelayDock Edge; the core API remains the supported path for custom consumers.)

Set `RELAYDOCK_CONFIG_DIR` or pass `configDirectory:` to `ProxyStore` to use another configuration directory. The library reuses existing proxy pools and does not migrate or delete user data.

## Custom JavaScript proxies

**Add One → Type → Custom (JS)** stores a named script instead of a fixed URL. In the wrapped flow the script runs inside RelayDock Edge each time a route is resolved, so it can fetch a fresh proxy from a provider API and rotate when the endpoint dies:

```js
if (!cache.url) {
  const res = await fetch("https://api.example.com/proxy", { headers: { "Authorization": "Bearer …" } });
  cache.url = (await res.json()).url; // or a "host:port" string
}
return cache.url;
```

- Scripts run in a sandboxed JavaScriptCore context with no file, process, or module access (`require`/`import` are unavailable). The surface is Node-flavoured but synchronous underneath: `fetch`/`await` (GET/HEAD/POST), `setTimeout`/`setInterval`, `URL`/`URLSearchParams`, `Buffer`, `TextEncoder`/`TextDecoder`, `crypto` (`createHash`/`createHmac` for SHA-256/384/512, `randomUUID`, `randomBytes`), `structuredClone`, `performance.now`, the synchronous `http.get(url, headers?)`/`http.post(url, body, headers?)` helpers (responses capped at 256 KB, request bodies at 64 KB), `btoa`, `atob`, and a no-op `console`. The script must `return` a proxy URL or `host:port`; the value is validated with the same parser as imported URLs.
- A global `cache` object persists between runs of the same entry (capped at 64 KB of JSON). Edge persists it to `<config>/script-cache.json`, so resolutions survive rotations and Edge restarts; the cache is keyed to a hash of the script, and editing the script drops its stale data immediately. It is also dropped whenever a run fails or times out; do not redeclare it in the script.
- Resolution is fail-closed: a script error, a 10-second timeout, or an invalid result throws `ProxyStoreError.scriptFailed`. With the wrapper this surfaces at request time — the launch itself never blocks on provider timing, Edge answers the first request with HTTP 502 if no upstream is usable, and traffic never falls back to direct. Health checks run the script first and record a failed check when it errors.
- Scripts can contain credentials and are stored as written in `<config>/proxies.json` (file permissions 0600). The app masks credentials in resolved previews.
- Rename or re-script an entry from the pool row's ⋯ menu (**Edit Script…**). Editing keeps the entry's identity, so Manual and sticky selections survive; changing the script clears its last recorded check and its in-memory `cache` (renaming keeps both).

## PATH wrapper for OpenCode

`scripts/opencode-wrapper.sh` installs an opt-in wrapper that applies the saved policy to new terminal `opencode` launches. The wrapper is deliberately thin: it reads `<config>/edge.json`, ensures **RelayDock Edge** is running, prints the routing line from Edge's status, and replaces itself with `opencode` under a **constant** proxy environment. Edge owns live resolution, rotation, health checks, and the script cache.

```sh
scripts/opencode-wrapper.sh install    # builds if needed; installs relaydock-launch + relaydock-edge; writes <config>/edge.json on first install; bootstraps the launchd KeepAlive agent
scripts/opencode-wrapper.sh status     # wrapper paths, agent state, + live Edge status (equivalent: relaydock-edge status)
scripts/opencode-wrapper.sh uninstall  # boots out the agent; stops Edge; removes the symlink, both binaries, and edge.json
```

Each launch:

- Reads `edge.json` (loopback port + per-install token). The port never renumbers silently once consumers hold the environment: if Edge cannot bind at runtime it exits loudly (`edge.log`) and the launcher refuses with a reinstall hint.
- Ensures Edge is running: with a socket-activated plist the launcher waits briefly for launchd to start Edge on the first connection (its status pings are the connection); otherwise a loaded KeepAlive agent is kickstarted (bootstrapped first if not loaded), else `relaydock-edge` is spawned detached. Concurrent starts are safe; the loser exits quietly, and `KeepAlive { SuccessfulExit: false }` means a clean loser-exit never respawn-loops.
- Prints one line to stderr from Edge's live status — `RelayDock: routed via Edge on 127.0.0.1:<port> — <entry> (<masked URL>)`, or a "first request resolves the upstream" note when Edge has not resolved yet; set `RELAYDOCK_QUIET=1` to silence it.
- Sets `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` (and lowercase variants) to the constant `http://<token>:@127.0.0.1:<port>`, merges `NO_PROXY=localhost,127.0.0.1` so the local OpenCode server keeps working, and removes `OPENCODE_SERVER_*` variables from the child environment. (The colon after the token is load-bearing: OpenCode's HTTP stack only sends `Proxy-Authorization` for a `username:password` userinfo; verified against the real binary.)
- Fails closed — exit 1, command not started, reinstall hint — when `edge.json` is missing or damaged or when Edge cannot be reached or started after spawning. Never a silent direct launch. Off mode launches the command with no proxy variables and never contacts Edge.

Edge itself:

- Resolves the selected entry (static URL or JavaScript script) on demand and single-flight; when a dial to the upstream fails it drops the cached script result, re-resolves, and retries once — **rotation no longer requires restarting anything**.
- Keeps one provider cooldown budget and one cache across all launches in `<config>/script-cache.json` (one-time adoption of the old `launcher-cache.json`); per-script hashes drop stale results the moment a script is edited.
- Pins extra loopback listeners when `edge.json` declares `listeners: [{port, entryID}]`: each such port serves exactly that pool entry — an explicit binding that ignores global Off mode and never falls back to direct — and `/status` lists every listener with its `activated` flag.
- Health-checks endpoints on a 10-minute cadence (with backoff after failures) and never blocks a launch on provider timing: if no upstream is usable, the **first request** gets HTTP 502 from Edge instead of a failed launch.
- Binds `127.0.0.1` only and requires the token on every proxy and admin request. `GET /__relaydock/status` reports mode, upstream, counters, and best-effort same-user tunnel attribution — it is a status surface, not a second control plane.

OpenCode's background service — not the CLI you start — performs model calls using the environment it was started with. Restart it once from a wrapped shell after installing the wrapper:

```sh
opencode service stop && opencode service start   # interrupts active sessions
```

With the constant environment, later endpoint rotations need no service restart. A cold start (no service running) inherits the wrapper's environment automatically. `opencode service restart` respawns the service without your shell environment — use stop + start.

The wrapper only affects commands started after it is installed; already-running processes and the app are untouched. It replaces itself with the command, so the launched process keeps the shell job's pid and foreground process group — terminal job control, Ctrl+C, and full-screen TUIs behave as if the wrapper were not there. Verify a launch independently (the routing line reports the environment the wrapper set, and Edge's status reports the tunnels it served — neither proves that every OpenCode process used a proxy):

```sh
ps eww -p <opencode pid> | tr ' ' '\n' | grep -i proxy
lsof -nP -iTCP -a -p <opencode pid> | grep ESTABLISHED
relaydock-edge status
```

`scripts/launcher-sandbox-test.sh` exercises the wrapper, Edge, and the installer end-to-end against a stub command, a fake `launchctl`, and local fake provider/proxies — cold start, warm sticky launch, live rotation, script-edit invalidation, the token gate, fail-closed paths, the spawn race, crash respawn, Off-mode checks, agent kickstart/bootout, socket activation (an inherited listener), pinned listeners, and job control — with no real OpenCode CLI, accounts, or network.

## Scope

Account login, usage reporting, quota recovery, app settings, and OpenCode process management are not part of this proxy-only app. Former behavior is recorded in [docs/REMOVED-FEATURES.md](docs/REMOVED-FEATURES.md) for historical reference. The interface follows the [proxy app wireframe](docs/PROXY-APP-WIREFRAME.md).

## License

MIT — see [LICENSE](LICENSE).
