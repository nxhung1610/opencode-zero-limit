# Product

## Platform

macos

## Users

Developers who want to manage a local proxy pool and routing policy for their own OpenCode setup.

## Product purpose

RelayDock provides a compact Preferences-style interface for proxy configuration and endpoint checks, backed by the `RelayDockCore` Swift package. The app saves policy locally; it does not launch, control, or restart OpenCode and cannot verify how OpenCode routes live traffic. An optional PATH wrapper pairs with **RelayDock Edge**, a loopback daemon, so new `opencode` launches read one stable proxy environment while the upstream rotates live.

## Capabilities

- Import and persist HTTP/HTTPS/SOCKS4/SOCKS4A/SOCKS5/SOCKS5H proxies, one at a time (typed fields) or in bulk.
- Support named custom JavaScript entries that resolve to a proxy at spawn time through a sandboxed JavaScriptCore script (no file, process, or module access), editable in place from the pool.
- Enable, disable, inspect, remove, and test configured proxies.
- Save Off, Manual, and Auto policies. Manual requires an enabled valid selection; Auto excludes known-failed checks and remains fail-closed when no candidate is usable.
- Expose a core library for consumers that independently select routes and construct a child-process proxy environment.
- Build an optional PATH wrapper plus the **RelayDock Edge** loopback daemon: launches get one constant, token-gated proxy environment; Edge resolves and rotates upstreams live (a failed dial re-resolves without restarting anything), owns a single hash-validated script cache (`script-cache.json`, one-time adoption of the legacy launcher cache), and keeps one provider cooldown budget.

## Constraints and safety

- A saved policy or passing endpoint check is not evidence that any OpenCode process is currently using a proxy.
- The app never silently converts Manual/Auto errors into Off/direct mode.
- The wrapper/Edge path is fail-closed: a missing or damaged `edge.json`, an unreachable or unstartable Edge, or a foreign process holding the Edge port refuses to launch the command (exit 1 with a reinstall hint) instead of falling back to direct. Edge binds `127.0.0.1` only and requires the per-install token on every request.
- A resolve failure at request time surfaces as HTTP 502 through Edge — the launch itself never blocks on provider timing and never leaks direct traffic.
- The PATH wrapper is opt-in and affects only commands started after installation; like the app, it reports the environment it configured and cannot verify live OpenCode traffic.
- Preserve the established proxy data path unless `RELAYDOCK_CONFIG_DIR` or `configDirectory:` overrides it.
- Native desktop only: macOS 14 or later first; no web build, browser UI, or mobile target in scope.
- Account login, usage, quota, unrelated settings, and process lifecycle management are out of scope. See `docs/REMOVED-FEATURES.md` for historical reference.

## Product experience

Use a compact native Preferences window with two icon tabs: Routing and Proxy Pool. Prefer Aqua controls, semantic system colors, native typography, visible state labels, keyboard access, and VoiceOver descriptions. Avoid dashboard styling and any status copy that implies unverified OpenCode routing.
