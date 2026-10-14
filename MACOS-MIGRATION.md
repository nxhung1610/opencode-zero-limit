# macOS-only migration

RelayDock is a native SwiftUI macOS app. The browser UI, RelayDock HTTP server, Node CLI, and web build have been removed. The pre-existing web UI diff remains as a local-only worktree backup and is intentionally excluded from this native app commit.

## Current progress

- [x] SwiftPM macOS app shell with native split-view navigation
- [x] Native Settings form backed by the existing configuration namespace
- [x] Preserve current settings keys, snake-case aliases, and corrupt settings files
- [x] Native proxy pool import, persistence, mode selection, masking, and fail-closed selection policy
- [x] Native proxy health checks through the configured proxy (including no-bypass verification)
- [x] Native OpenCode process start/stop, binary lookup, v1/v2 health probes, local auth, and proxy environment
- [x] Native Console OAuth start/poll/cancel/code, safe metadata listing, account activation, and removal
- [x] Read-only local SQLite usage summaries and active-account-aware sticky proxy bindings
- [x] Native quota-event SSE monitoring with account rotation for OpenCode v1 orgs and v2 credentials
- [x] Native core regression tests (30 passing)
- [x] Isolated real-CLI compatibility smoke on OpenCode v1.18.35 and v2.0.26
- [x] Safe native removal of an obsolete RelayDock PATH-wrapper symlink
- [x] Remove browser UI, HTTP API, npm/Vite stack, and web-only CI/docs
- [ ] Actual macOS-window visual/accessibility QA
- [ ] OAuth/account-rotation and proxy tests with dedicated test credentials/endpoints
- [ ] Verify app bundle on minimum macOS 14 and add signing/notarization for distribution

## Build

Requires macOS 14 or later and Swift 6:

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
```

The native app manages proxy configuration and health tests, routes its managed OpenCode process according to Off/Manual/Auto policy, supports Console account management on v2 and organization rotation on v1, reads local usage counters read-only, and watches local SSE quota events. Isolated live-CLI smoke checks passed against OpenCode v1.18.35 and v2.0.26. Actual UI/accessibility QA and account/proxy flows with dedicated real test credentials/endpoints remain unverified.
