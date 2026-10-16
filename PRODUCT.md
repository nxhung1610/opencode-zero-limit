# Product

## Platform

macos

## Users

Developers who want to manage a local proxy pool and routing policy for their own OpenCode setup.

## Product purpose

RelayDock provides a compact Preferences-style interface for proxy configuration and endpoint checks, backed by the `RelayDockCore` Swift package. The app saves policy locally; it does not launch, control, or restart OpenCode and cannot verify how OpenCode routes live traffic.

## Capabilities

- Import and persist HTTP/HTTPS/SOCKS5/SOCKS5H proxies.
- Enable, disable, inspect, remove, and test configured proxies.
- Save Off, Manual, and Auto policies. Manual requires an enabled valid selection; Auto excludes known-failed checks and remains fail-closed when no candidate is usable.
- Expose a core library for consumers that independently select routes and construct a child-process proxy environment.

## Constraints and safety

- A saved policy or passing endpoint check is not evidence that any OpenCode process is currently using a proxy.
- The app never silently converts Manual/Auto errors into Off/direct mode.
- Preserve the established proxy data path unless `RELAYDOCK_CONFIG_DIR` or `configDirectory:` overrides it.
- Native desktop only: macOS 14 or later first; no web build, browser UI, or mobile target in scope.
- Account login, usage, quota, unrelated settings, and process lifecycle management are out of scope. See `docs/REMOVED-FEATURES.md` for historical reference.

## Product experience

Use a compact native Preferences window with two icon tabs: Routing and Proxy Pool. Prefer Aqua controls, semantic system colors, native typography, visible state labels, keyboard access, and VoiceOver descriptions. Avoid dashboard styling and any status copy that implies unverified OpenCode routing.
