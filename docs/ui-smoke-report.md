# UI smoke and visual review

`npm run ui:smoke` launches a fresh Vite server and headless Chrome/Chromium, injects a mocked same-origin HTTP API (session, commands, and quota events), exercises onboarding, browser-based OpenCode Console sign-in link/polling, connection activation, and recoverable API failures, then captures all four pages in light and dark themes at six responsive viewport sizes. The detailed UI suite does not use real account or proxy credentials.

## Results

- `npm run build` — passed (TypeScript server compilation, frontend `tsc`, and Vite 8.3.4 production build; 2022 client modules transformed).
- `npm run ui:smoke` — passed: onboarding flow + **48 page/theme/viewport combinations** (4 routes × 2 themes × 6 viewport sizes).
- Viewports: **390×844**, **680×820**, **800×560**, **960×680**, **1024×820**, and **1440×900**.
- Responsive checks: no document, body, or main-content horizontal overflow in any case.
- Accessibility tree: every case exposed named interactive controls plus named navigation and `main` landmarks; no visible interactive control was unnamed. No unexpected `role="alert"` appeared in the healthy state.
- Keyboard traversal: Tab traversal ran on all 48 cases and reached every named control with visible focus. There were **557 focus stops**; the lowest measured focus-outline contrast was **4.98:1** (light minimum 4.98:1; dark minimum 7.1:1), above the 3:1 non-text threshold.
- Text contrast: **2,184 visible text/placeholder measurements** across the matrix; minimum was **4.83:1**, above the 4.5:1 normal-text WCAG AA threshold. There were no low-contrast text nodes, disabled-text failures, or unverified backgrounds.
- Recoverable failures: injected local HTTP command failures for Accounts (`console_connections`), Usage (`usage_summary`), Proxies (`proxy_list`), and Settings (`settings_get`) each exposed an accessible alert and named “Try again” button; retry recovered.
- Node backend tests: **10 passed** with `npm test`, including v1/v2 health probing, managed child-process lifecycle, v2 browser OAuth attempt lifecycle with a fake OpenCode API, HTTPS-only sign-in links, safe connection metadata filtering, activation/removal, built-in SQLite usage queries, loopback Host/same-origin protections, legacy settings/proxy serialization, default CLI wrapper proxy environment, quota-event parsing, v1/v2 event-stream routing, and the local HTTP API.
- OpenCode v2 runtime check: launched isolated `opencode v2.0.26`, confirmed Basic-authenticated `/api/info` health and read the empty `/api/credential` list through RelayDock without modifying the user's OpenCode data. The browser link and attempt lifecycle are covered by deterministic API tests and UI smoke; no real account was authorized.
- OpenCode v1 contract test: passed against a temporary, isolated `opencode-ai@1.18.35` install; all 6 required API paths were present among 162 documented paths, with health `{healthy:true, version:"1.18.35"}`.
- Visual review: smoke captured all 48 page/theme/viewport combinations; the Accounts interaction test verified that Add account displays a new-tab browser sign-in link, polls to completion, lists the saved connection, and activates another connection. The full screenshot matrix is linked below.

## First-run view

[Open onboarding screenshot](../artifacts/ui-smoke/onboarding-first-run.png) · 680×820

## Page screenshots

Each image opens at its captured resolution. The 48 cases cover Accounts, Usage, Proxies, and Settings across six viewport sizes and both themes.

| Theme · viewport | Accounts | Usage | Proxies | Settings |
| --- | --- | --- | --- | --- |
| Light · 390×844 | [PNG](../artifacts/ui-smoke/light-mobile-accounts.png) | [PNG](../artifacts/ui-smoke/light-mobile-usage.png) | [PNG](../artifacts/ui-smoke/light-mobile-proxy.png) | [PNG](../artifacts/ui-smoke/light-mobile-settings.png) |
| Light · 680×820 | [PNG](../artifacts/ui-smoke/light-narrow-accounts.png) | [PNG](../artifacts/ui-smoke/light-narrow-usage.png) | [PNG](../artifacts/ui-smoke/light-narrow-proxy.png) | [PNG](../artifacts/ui-smoke/light-narrow-settings.png) |
| Light · 800×560 | [PNG](../artifacts/ui-smoke/light-minimum-accounts.png) | [PNG](../artifacts/ui-smoke/light-minimum-usage.png) | [PNG](../artifacts/ui-smoke/light-minimum-proxy.png) | [PNG](../artifacts/ui-smoke/light-minimum-settings.png) |
| Light · 960×680 | [PNG](../artifacts/ui-smoke/light-default-accounts.png) | [PNG](../artifacts/ui-smoke/light-default-usage.png) | [PNG](../artifacts/ui-smoke/light-default-proxy.png) | [PNG](../artifacts/ui-smoke/light-default-settings.png) |
| Light · 1024×820 | [PNG](../artifacts/ui-smoke/light-medium-accounts.png) | [PNG](../artifacts/ui-smoke/light-medium-usage.png) | [PNG](../artifacts/ui-smoke/light-medium-proxy.png) | [PNG](../artifacts/ui-smoke/light-medium-settings.png) |
| Light · 1440×900 | [PNG](../artifacts/ui-smoke/light-wide-accounts.png) | [PNG](../artifacts/ui-smoke/light-wide-usage.png) | [PNG](../artifacts/ui-smoke/light-wide-proxy.png) | [PNG](../artifacts/ui-smoke/light-wide-settings.png) |
| Dark · 390×844 | [PNG](../artifacts/ui-smoke/dark-mobile-accounts.png) | [PNG](../artifacts/ui-smoke/dark-mobile-usage.png) | [PNG](../artifacts/ui-smoke/dark-mobile-proxy.png) | [PNG](../artifacts/ui-smoke/dark-mobile-settings.png) |
| Dark · 680×820 | [PNG](../artifacts/ui-smoke/dark-narrow-accounts.png) | [PNG](../artifacts/ui-smoke/dark-narrow-usage.png) | [PNG](../artifacts/ui-smoke/dark-narrow-proxy.png) | [PNG](../artifacts/ui-smoke/dark-narrow-settings.png) |
| Dark · 800×560 | [PNG](../artifacts/ui-smoke/dark-minimum-accounts.png) | [PNG](../artifacts/ui-smoke/dark-minimum-usage.png) | [PNG](../artifacts/ui-smoke/dark-minimum-proxy.png) | [PNG](../artifacts/ui-smoke/dark-minimum-settings.png) |
| Dark · 960×680 | [PNG](../artifacts/ui-smoke/dark-default-accounts.png) | [PNG](../artifacts/ui-smoke/dark-default-usage.png) | [PNG](../artifacts/ui-smoke/dark-default-proxy.png) | [PNG](../artifacts/ui-smoke/dark-default-settings.png) |
| Dark · 1024×820 | [PNG](../artifacts/ui-smoke/dark-medium-accounts.png) | [PNG](../artifacts/ui-smoke/dark-medium-usage.png) | [PNG](../artifacts/ui-smoke/dark-medium-proxy.png) | [PNG](../artifacts/ui-smoke/dark-medium-settings.png) |
| Dark · 1440×900 | [PNG](../artifacts/ui-smoke/dark-wide-accounts.png) | [PNG](../artifacts/ui-smoke/dark-wide-usage.png) | [PNG](../artifacts/ui-smoke/dark-wide-proxy.png) | [PNG](../artifacts/ui-smoke/dark-wide-settings.png) |

## Reproduce and inspect

```bash
npm run ui:smoke
```

Requires Node 22.13+ and Chrome/Chromium (`CHROME_BIN` can specify a nonstandard executable path). The run writes an [HTML screenshot gallery](../artifacts/ui-smoke/index.html), individual PNGs, and machine-readable [`results.json`](../artifacts/ui-smoke/results.json) under `artifacts/ui-smoke/`.

## Scope and limitations

This is a deterministic browser smoke and visual review, not a full WCAG conformance audit or a VoiceOver session. It checks visible text/placeholder contrast, keyboard focus-outline contrast, and the browser accessibility tree, but actual screen-reader speech and non-text contrast for every icon/control boundary are not independently audited. The screenshot UI suite uses a mocked local HTTP API; the separate local CLI check exercised the real loopback web host/API, but `opencode_status` intentionally had no running OpenCode server. No real account or proxy credentials were used.
