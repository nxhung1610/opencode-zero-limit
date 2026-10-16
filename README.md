# RelayDock for macOS

RelayDock is a compact native SwiftUI utility for managing a local proxy pool and its Off/Manual/Auto policy. It can import proxies and test enabled endpoints. It does **not** launch or restart OpenCode, apply the saved policy to an OpenCode process, or verify live OpenCode traffic.

**Platform:** macOS 14 or later. **Language:** Swift 6.

## What it provides

- Import and persist HTTP, HTTPS, SOCKS5, and SOCKS5H proxy URLs.
- Enable, disable, remove, and health-check proxies in the local pool.
- Save Off, Manual, or Auto policy. Manual and Auto configuration remains fail-closed; invalid or missing routes are not silently changed to Off.
- Preserve existing proxy data at `~/Library/Application Support/com.nxhung.opencodezerolimit/proxies.json` with restrictive file permissions.
- Provide `RelayDockCore` helpers for consumers that launch their own child process and need to select a route and construct proxy environment variables.

A successful endpoint check only reports that the configured proxy endpoint passed that check. Neither a saved policy nor a successful check proves that OpenCode traffic used a proxy.

## Build, test, and run

Requires macOS 14+ and Swift 6:

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
open build/RelayDock.app
```

The app is currently unsigned and not notarized for public distribution.

## Core library

Add the `macOS/RelayDock` Swift package and import `RelayDockCore` from a process-launching consumer:

```swift
import RelayDockCore

let proxies = ProxyStore()
let selectedProxyURL = try proxies.selectForSpawn()
let childEnvironment = buildOpenCodeProxyEnvironment(proxyURL: selectedProxyURL)
```

`selectForSpawn()` returns `nil` only for explicit Off mode. Do not catch a Manual/Auto selection error and continue with `nil`; surface the error and do not launch the child process. Auto may use enabled proxies whose health is unknown, but excludes proxies whose last recorded check failed. The consumer must actually use the returned environment when launching the child and must independently verify its HTTP client's behavior.

Set `RELAYDOCK_CONFIG_DIR` or pass `configDirectory:` to `ProxyStore` to use another configuration directory. The library reuses existing proxy pools and does not migrate or delete user data.

## Scope

Account login, usage reporting, quota recovery, app settings, and OpenCode process management are not part of this proxy-only app. Former behavior is recorded in [docs/REMOVED-FEATURES.md](docs/REMOVED-FEATURES.md) for historical reference. The interface follows the [proxy app wireframe](docs/PROXY-APP-WIREFRAME.md).

## License

MIT — see [LICENSE](LICENSE).
