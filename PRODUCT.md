# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Individual developers using the OpenCode CLI who want to manage their own local OpenCode setup and keep it usable on the free tier.

## Product Purpose

RelayDock is a local browser companion for OpenCode, launched with the `relaydock serve` CLI command. It shows local usage and quota-hit signals, manages OpenCode Console connections, controls the local `opencode serve` process, and supports proxy routing and account rotation. A TypeScript/Node.js host runs on the user's machine and serves the UI over loopback HTTP; there is no Rust backend, desktop window, tray app, installer, or hosted/cloud backend.

## Positioning

Unlike a usage-only dashboard, RelayDock connects local usage and quota-hit detection to actionable Console connection switching, optional automatic rotation, and proxy routing. OpenCode does not expose a reliable remaining-quota count, so the product reports observed usage and quota hits rather than predicting requests remaining.

## Operating Context

The user-facing app runs in a regular browser, started from a terminal with `relaydock serve`. A local Node.js host binds only to `127.0.0.1`, serves the React build, exposes a same-origin HTTP command API and quota-event stream, and owns local process/config access; no native window or tray is created. It can control a local `opencode serve` process. For OpenCode v2, Add account starts the local OAuth device flow and displays the generated sign-in link in the browser. OpenCode itself saves the credential to its local database; RelayDock does not import or expose credential values. Switching or removing a v2 Console connection uses the local OpenCode API. Usage counters are read from OpenCode's local SQLite database via Node's built-in `node:sqlite`; quota events are observed from the authenticated server event stream. Proxy configuration is applied to the managed server and, with the opt-in PATH wrapper, ordinary `opencode` commands. The wrapper delegates to the installed OpenCode binary and adds the selected proxy environment without replacing that binary. No app data is sent to a hosted service by this UI/API layer.

## Capabilities and Constraints

- Scope is OpenCode CLI; do not imply support for unrelated providers or hosted account management.
- The four current product areas are Accounts, Usage, Proxies, and Settings. Preserve their existing capabilities and navigation labels during the visual redesign.
- Users can connect OpenCode Console accounts through a browser sign-in link, activate or remove saved connections, start or stop the local server, inspect local usage, configure proxy pools, and manage automatic rotation and other local settings.
- Free-tier quota is dynamic and enforced remotely. There is no supported API for an exact remaining-request count; show a detected quota hit, not a fabricated quota estimate.
- Preserve user control and communicate server restarts, proxy state, and automatic account rotation clearly.
- Runtime requirement: Node.js 22.13+; no Rust/Cargo toolchain or desktop shell.
- The managed-server health probe supports OpenCode v1 (`/global/health`) and v2 (`/api/info` with local Basic authentication). Browser-based Console connection management requires v2; the v1 API contract remains tested against `1.18.35`.

## Brand Commitments

The product name is RelayDock. The existing mark at `brand/icon.svg` is incumbent brand material and should not be replaced without explicit approval. The user-approved visual direction is a dark operations/observability console inspired by the supplied topology screenshot: grouped navigation, a persistent live-status header, dense task workspaces, and a truthful account-to-proxy-to-server route graph. Use grayscale surfaces and neutral type with blue as the sole accent; communicate other states with explicit labels, icons, and shape rather than color alone. Default to dark while retaining the light/dark/system theme toggle, and compose each theme deliberately. Render the existing mark in grayscale without changing its source asset. Keep the compact layout and make completed onboarding guidance reopenable.

## Evidence on Hand

- `README.md` documents the local web UI, terminal install/run flow, capabilities, quota limitations, runtime requirements, and OpenCode API compatibility.
- `PLAN.md` documents the OpenCode-only scope and account/quota/proxy workflows.
- The existing source under `src/` contains Accounts, Usage, Proxies, and Settings surfaces.
- `docs/ui-smoke-report.md` and `artifacts/ui-smoke/` contain responsive, light/dark, keyboard, contrast, error-state, and browser HTTP-API smoke evidence. No real account or proxy credentials were used in the captures.
- Do not invent remaining-quota counts, customer claims, or benchmark figures.

## Product Principles

- Distinguish measured local usage from remotely enforced quota availability.
- Make recovery actions clear when the local service or active account is unavailable.
- Keep account switching and proxy/rotation controls local, explicit, and understandable.
- Preserve existing working behavior while improving visual hierarchy and reducing time to common tasks.
