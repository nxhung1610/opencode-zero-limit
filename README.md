# RelayDock for macOS

RelayDock is a compact native SwiftUI utility for managing a local proxy pool and its Off/Manual/Auto policy. It can import proxies and test enabled endpoints. It does **not** launch or restart OpenCode, apply the saved policy to an OpenCode process, or verify live OpenCode traffic.

**Platform:** macOS 14 or later. **Language:** Swift 6.

## What it provides

- Import and persist HTTP, HTTPS, SOCKS4, SOCKS4A, SOCKS5, and SOCKS5H proxy URLs — one at a time or in bulk.
- Support named custom JavaScript entries that resolve to a proxy each time a consumer launches a child process.
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

`selectForSpawn()` returns `nil` only for explicit Off mode. Do not catch a Manual/Auto selection error and continue with `nil`; surface the error and do not launch the child process. Auto may use enabled proxies whose health is unknown, but excludes proxies whose last recorded check failed. When the selection is a custom JavaScript entry, `selectForSpawn()` runs the script first; a script error, timeout, or invalid result is thrown so the launch stays fail-closed. The consumer must actually use the returned environment when launching the child and must independently verify its HTTP client's behavior.

Set `RELAYDOCK_CONFIG_DIR` or pass `configDirectory:` to `ProxyStore` to use another configuration directory. The library reuses existing proxy pools and does not migrate or delete user data.

## Custom JavaScript proxies

**Add One → Type → Custom (JS)** stores a named script instead of a fixed URL. The script runs inside `selectForSpawn()` each time a consumer launches a child process, so it can fetch a fresh proxy from a provider API:

```js
if (!cache.url) {
  const res = await fetch("https://api.example.com/proxy", { headers: { "Authorization": "Bearer …" } });
  cache.url = (await res.json()).url; // or a "host:port" string
}
return cache.url;
```

- Scripts run in a sandboxed JavaScriptCore context with no file, process, or module access (`require`/`import` are unavailable). The surface is Node-flavoured but synchronous underneath: `fetch`/`await` (GET/HEAD/POST), `setTimeout`/`setInterval`, `URL`/`URLSearchParams`, `Buffer`, `TextEncoder`/`TextDecoder`, `crypto` (`createHash`/`createHmac` for SHA-256/384/512, `randomUUID`, `randomBytes`), `structuredClone`, `performance.now`, the synchronous `http.get(url, headers?)`/`http.post(url, body, headers?)` helpers (responses capped at 256 KB, request bodies at 64 KB), `btoa`, `atob`, and a no-op `console`. The script must `return` a proxy URL or `host:port`; the value is validated with the same parser as imported URLs.
- A global `cache` object persists between runs of the same entry — in memory only, per process, capped at 64 KB of JSON. It is dropped whenever a run fails or times out; do not redeclare it in the script.
- Resolution is fail-closed: a script error, a 10-second timeout, or an invalid result throws `ProxyStoreError.scriptFailed` — the consumer must not launch without a proxy. Health checks run the script first and record a failed check when it errors.
- Scripts can contain credentials and are stored as written in `<config>/proxies.json` (file permissions 0600). The app masks credentials in resolved previews.

## Scope

Account login, usage reporting, quota recovery, app settings, and OpenCode process management are not part of this proxy-only app. Former behavior is recorded in [docs/REMOVED-FEATURES.md](docs/REMOVED-FEATURES.md) for historical reference. The interface follows the [proxy app wireframe](docs/PROXY-APP-WIREFRAME.md).

## License

MIT — see [LICENSE](LICENSE).
