# Product

## Platform

Aqua (native macOS desktop); minimum macOS 14.

## Users

Individual developers running the OpenCode CLI on their Mac who want to manage local accounts, usage, proxies, and quota recovery from a native desktop window.

## Product purpose

RelayDock manages the user's local OpenCode server process and configuration through a macOS-native interface. It reads usage data from OpenCode's local SQLite database, observes quota-hit events from the managed server, and can switch among locally saved accounts/orgs. There is no browser frontend, RelayDock HTTP host, Node.js runtime, or hosted backend.

## Capabilities

- Accounts: OpenCode v2 browser OAuth lifecycle and safe local credential metadata; v1 organization switching for quota rotation.
- Usage: read-only local message, token, cost, model, session, and active-account summaries.
- Proxies: HTTP/HTTPS/SOCKS5 import and health checks; Off, Manual, and Auto modes; sticky account-to-proxy bindings; fail-closed proxy selection.
- Quota: local SSE monitoring for supported retry quota events and optional account rotation.
- Settings: auto-start, auto-rotation, CLI path, appearance, and safe removal of an obsolete RelayDock PATH-wrapper symlink.

## Constraints and safety

- OpenCode is the only supported CLI/provider.
- Do not claim an exact remaining-quota count; OpenCode does not provide a stable supported local remaining-quota API.
- OpenCode owns and stores account secrets. RelayDock only displays safe metadata.
- All managed server traffic is loopback-only. No RelayDock server is exposed to a browser.
- Proxy Manual/Auto must never fall back to direct; direct access is explicit Off mode.
- Preserve the existing local settings/proxy namespace unless the user overrides it with `RELAYDOCK_CONFIG_DIR`.

## Product experience

Use macOS-native navigation, toolbar, forms, dialogs, typography, controls, and accessibility conventions. The app should feel at home next to other SwiftUI utilities—not like a website inside a desktop window.
