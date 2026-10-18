# Product

## Platform

macos

## Users

Developers who want to manage a local proxy pool and routing policy for their own OpenCode setup.

## Product purpose

RelayDock provides a compact Preferences-style interface for proxy configuration and endpoint checks, backed by the `RelayDockCore` Swift package. The app saves policy locally; it does not launch, control, or restart OpenCode. With the optional PATH wrapper, **RelayDock Edge** — a loopback daemon — gives new `opencode` launches one stable proxy environment, rotates the upstream live, and reports its own tunnel accounting, which the app renders as the Edge status panel. Edge-routed traffic is the only traffic the product can speak to; direct traffic stays invisible.

## Capabilities

- Import and persist HTTP/HTTPS/SOCKS4/SOCKS4A/SOCKS5/SOCKS5H proxies, one at a time (typed fields) or in bulk.
- Support named custom JavaScript entries that resolve to a proxy at spawn time through a sandboxed JavaScriptCore script (no file, process, or module access), editable in place from the pool.
- Enable, disable, inspect, remove, and test configured proxies.
- Save Off, Manual, and Auto policies. Manual requires an enabled valid selection; Auto excludes known-failed checks and remains fail-closed when no candidate is usable.
- Expose a core library for consumers that independently select routes and construct a child-process proxy environment.
- Build an optional PATH wrapper plus the **RelayDock Edge** loopback daemon: launches get one constant, token-gated proxy environment; Edge resolves and rotates upstreams live (a failed dial re-resolves without restarting anything), owns a single hash-validated script cache (`script-cache.json`, one-time adoption of the legacy launcher cache), and keeps one provider cooldown budget.
- Show Edge live: a status panel on the Routing tab (mode, upstream with expiry, counters, cooldown, tunnel attribution per peer process) and a compact Edge line in the menu bar popover; `Test All` delegates to Edge and falls back in-process, labeled, only when Edge is unreachable.
- Supervise Edge with a launchd KeepAlive agent written and bootstrapped by the installer (crash restarts within seconds; clean loser-exits never respawn-loop); the launcher kickstarts a loaded agent before falling back to spawning the binary.

## Constraints and safety

- A saved policy or passing endpoint check is not evidence that any OpenCode process is currently using a proxy. Edge's tunnel accounting is evidence for Edge-routed traffic only — "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible."
- The app never silently converts Manual/Auto errors into Off/direct mode.
- The wrapper/Edge path is fail-closed: a missing or damaged `edge.json`, an unreachable or unstartable Edge, or a foreign process holding the Edge port refuses to launch the command (exit 1 with a reinstall hint) instead of falling back to direct. Edge binds `127.0.0.1` only and requires the per-install token on every request.
- A resolve failure at request time surfaces as HTTP 502 through Edge — the launch itself never blocks on provider timing and never leaks direct traffic.
- The PATH wrapper is opt-in and affects only commands started after installation; it reports the environment it configured, and the app shows Edge's own accounting — neither claims anything about traffic that bypasses Edge.
- Preserve the established proxy data path unless `RELAYDOCK_CONFIG_DIR` or `configDirectory:` overrides it.
- Native desktop only: macOS 14 or later first; no web build, browser UI, or mobile target in scope.
- Account login, usage, quota, unrelated settings, and process lifecycle management are out of scope. See `docs/REMOVED-FEATURES.md` for historical reference.

## Product experience

Use a compact native Preferences window with two icon tabs: Routing and Proxy Pool. Prefer Aqua controls, semantic system colors, native typography, visible state labels, keyboard access, and VoiceOver descriptions. Avoid dashboard styling; status copy may report Edge's own accounting but must never imply more than Edge-routed traffic is verified.
