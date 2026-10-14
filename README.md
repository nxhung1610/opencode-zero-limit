# RelayDock for macOS

RelayDock is a native SwiftUI companion for the OpenCode CLI. It runs as a macOS app, manages a local `opencode serve` process, and keeps account, usage, proxy, and quota controls on this Mac.

**Platform:** macOS 14 or later. **No browser UI, local RelayDock HTTP server, Node.js runtime, or web build is used.**

## Features

- **Accounts:** OpenCode v2 Console OAuth sign-in, safe saved-account metadata, activate/remove; quota rotation also supports v1 organizations.
- **Usage:** read-only summaries from OpenCode's local SQLite database. It reports observed usage, not a fabricated remaining-quota estimate.
- **Quota:** watches the managed OpenCode event stream and can rotate to another saved account/org after supported quota-hit events. Rotation is optional and has a cooldown.
- **Proxies:** import and test HTTP/HTTPS/SOCKS5 proxies; select Off, Manual, or Auto. Manual and Auto fail closed rather than silently using a direct connection. Auto keeps sticky proxy bindings by active account.
- **Settings:** auto-start, auto-rotation, OpenCode binary path, and appearance. A guarded action can remove the old RelayDock PATH-wrapper symlink without changing the installed OpenCode binary.

RelayDock never reads or stores OpenCode credential values. OAuth credentials remain in OpenCode's local store. All app state and OpenCode API traffic stay local; the managed API binds to loopback.

## Build and test

Requires macOS 14+ and Swift 6:

```sh
swift test --package-path macOS/RelayDock
scripts/build-macos-app.sh
open build/RelayDock.app
```

The app bundle is built locally and is not currently signed/notarized for public distribution.

## OpenCode compatibility smoke

With an installed OpenCode v1 or v2 binary:

```sh
OPENCODE_BIN=/absolute/path/to/opencode scripts/smoke-opencode-macos.sh
```

This starts the real CLI against an isolated temporary HOME/XDG data directory, verifies version-specific health/account/event endpoints, and stops the managed process. It does not use or modify your saved accounts. We smoke-tested OpenCode v1.18.35 and v2.0.26.

## Local data and legacy wrapper

Existing settings and proxy pools are reused from:

```text
~/Library/Application Support/com.nxhung.opencodezerolimit/
```

Set `RELAYDOCK_CONFIG_DIR` to use a different configuration directory.

The old optional `~/.local/bin/opencode` wrapper is no longer installed or required. Open **Settings → Legacy Terminal Wrapper** to inspect and safely remove a symlink managed by an earlier RelayDock checkout. The real OpenCode binary and unrelated files are left untouched.

## Scope

RelayDock supports the OpenCode CLI only and is macOS-only. Accounts and browser OAuth are available on OpenCode v2; v1 supports organization switching and quota rotation, but not the v2 OAuth account UI. OpenCode's quota is enforced remotely and changes dynamically; RelayDock shows observed quota events rather than an exact remaining count.

## License

MIT — see [LICENSE](LICENSE).
