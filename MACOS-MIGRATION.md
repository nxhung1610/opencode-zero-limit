# macOS proxy-only app

RelayDock is a native SwiftUI macOS app backed by the `RelayDockCore` Swift package. The app manages proxy settings and endpoint health only. The broader account, usage, quota, and OpenCode process-management features from the former companion app remain removed.

## Current scope

- Preferences-style Routing and Proxy Pool tabs.
- Local proxy-pool persistence, import, masked display, enable/disable, removal, and endpoint checks.
- Off, Manual, and Auto policy management with fail-closed selection rules.
- Core helpers for process-launching consumers to construct proxy environment variables.
- No OpenCode process launch/restart, account login, usage view, quota recovery, or unrelated app settings.

Saving a policy or passing a proxy health check does not prove that OpenCode traffic uses that route. Existing proxy pools continue to use the established configuration path; this refactor does not remove user data.

## Build and test

Requires macOS 14 or later and Swift 6:

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
open build/RelayDock.app
```

The app is not signed or notarized for distribution. Former account/login, usage, quota, settings, and process behavior is described in `docs/REMOVED-FEATURES.md` for historical reference only.
