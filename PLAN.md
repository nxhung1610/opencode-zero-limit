# RelayDock — Web-first plan

## Product target

A local browser companion for OpenCode. Users start it from a terminal with `relaydock serve`; it opens the React UI in a browser and serves local control APIs from a TypeScript/Node.js process bound to loopback. The product is not a desktop window, tray application, or OS installer. No Rust toolchain is required.

## Decisions

| Area | Decision |
| --- | --- |
| Deployment | Local-only; bind to `127.0.0.1`, no hosted account/data service |
| Entry point | Dedicated `relaydock serve`; an opt-in PATH wrapper delegates ordinary `opencode` commands to the real CLI while applying RelayDock's selected proxy |
| UI | React + TypeScript + Tailwind in a normal browser |
| Local backend | TypeScript/Node.js host owns the OpenCode process, config, proxy, SQLite, and quota-event access |
| Quota | Report measured local usage and observed quota hits; never claim an exact remaining-request count |
| Scope | OpenCode CLI only; preserve Accounts, Usage, Proxies, and Settings capabilities |
| User data | Keep using the former Tauri application identifier as the config-directory namespace to preserve local settings/proxy files |
| Runtime | Node.js 22.13+; use built-in `node:sqlite`, no Rust/Cargo backend |

## Launch lifecycle

1. Build the Node server and frontend with `npm run build`.
2. Link the checkout into the user's npm command path with `npm link`.
3. Run `relaydock serve` from OpenCode's integrated terminal or another shell.
4. Start the loopback service, optionally write a ready URL for integration tests, and open the browser; `--no-open` prints the URL only.
5. Keep the process attached to the terminal. Ctrl+C stops the app and its managed local OpenCode server.

The command is an ordinary shell executable, not an OpenCode slash command or plugin. RelayDock does not replace the installed OpenCode binary; an opt-in PATH symlink delegates `opencode` invocations to that real binary with the selected proxy environment.

## Current implementation

- `bin/relaydock.cjs` parses `serve` and opt-in proxy-wrapper management commands, then loads the compiled TypeScript service.
- `server/webServer.ts` serves `dist/` and a same-origin API on an ephemeral loopback port. Mutating requests and quota events use a per-run token; Host and Origin are checked.
- `server/opencode.ts`, `server/console.ts`, `server/usage.ts`, `server/proxy.ts`, `server/settings.ts`, and `server/watcher.ts` own local process, Console, SQLite, proxy, settings, and event behavior.
- The browser uses `src/services/bridge.ts` for the HTTP API and event stream; no Tauri JavaScript APIs or native window exist.
- Local settings and proxy JSON remain under the legacy app-config namespace. `RELAYDOCK_CONFIG_DIR` can override the config directory.

## OpenCode compatibility

The managed process detects the locally installed CLI major. V1 health checks use `/global/health`; v2 health checks use Basic-authenticated `/api/info` with a random per-run password held by the Node host. The Accounts UI uses the v2 `opencode` integration: RelayDock starts the OAuth device attempt, renders the returned browser link, polls its status, and refreshes safe connection metadata. OpenCode stores credentials in its local database; credential values are never returned to the browser. The v1 OpenCode API contract remains pinned to `opencode-ai@1.18.35` in CI; browser-based account management requires v2.

## Verification checklist

- `npm run build` — compile TypeScript backend and frontend production assets.
- `npm test` — verify server security, v1/v2 process health probes, v2 OAuth-link lifecycle and safe connection metadata, settings/proxy compatibility, default CLI wrapper environment, quota parsing, and local HTTP API behavior.
- `npm run ui:smoke` — browser-level interaction, accessibility, responsive, light/dark, and error-recovery checks using a mocked local HTTP API.
- `bash scripts/contract-test.sh` — verify the supported OpenCode API surface against the pinned v1 CLI.
- CLI integration — start with `relaydock serve --no-open`, verify the ready URL and local endpoints, then stop cleanly with Ctrl+C.

## Future work

- Decide whether to remove the retained v1 organization-switching fallback once v2 connections are the only supported account model.
- Publish a versioned CLI package if installation without a source checkout is desired.
- Continue improving the browser UI and smoke coverage without introducing desktop-specific UI or installers.
