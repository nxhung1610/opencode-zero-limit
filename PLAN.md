# RelayDock — macOS-only plan

## Product target

A native SwiftUI macOS app for local OpenCode account, usage, proxy, server, and quota management. No web UI, RelayDock HTTP API, Node runtime, or non-macOS packaging.

## Implemented

- SwiftPM app shell with native split navigation, toolbar, forms, dialogs, and system appearance.
- Legacy settings/proxy data compatibility and restricted file permissions.
- Managed OpenCode v1/v2 process lifecycle, health checks, v2 local server auth, and fail-closed proxy environment.
- v2 Console OAuth and safe connection metadata; v1 organization listing/switching.
- Read-only SQLite usage summaries and active-account-aware proxy selection.
- Quota SSE monitoring, cooldown, and v1/v2 account rotation.
- Safe removal of the old optional PATH wrapper symlink.
- Unit/regression tests and isolated real-CLI smoke checks for v1.18.35 and v2.0.26.
- Removal of the browser UI, local HTTP API, npm/Vite project, and web-only CI/docs.

## Remaining work

1. Finish visual/accessibility QA on the actual macOS window and validate account OAuth/rotation using test credentials and real proxy endpoints.
2. Verify the built app bundle on the minimum supported macOS release.
3. Add signing/notarization and a stable release/install flow before claiming public distribution.

## Verification

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
plutil -lint build/RelayDock.app/Contents/Info.plist
OPENCODE_BIN=/path/to/opencode scripts/smoke-opencode-macos.sh
```
