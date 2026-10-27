# RelayDock proxy app — wireframe variants

> **Current shell (October 2026):** The shipped app is a native macOS window: a `NavigationSplitView` with a **Routing** / **Proxy Pool** sidebar, a real toolbar with **Test All** and **Import Proxies**, grouped forms and an inset proxy list, and system controls. Default window **760×580 outer** (760×528 content under the unified toolbar) with a **680×500 content minimum**; the menu bar panel stays **360pt wide**. The variants below are the original wireframe exploration and no longer describe the app; they are kept for history.

**Status:** implemented — config-only SwiftUI app with the P2 RelayDock Edge panel, delegated checks, an Edge line in the sidebar and menu bar panel, a shared routing-state presentation for the Routing page and panel anchor, and the routing setup section that installs/uninstalls the PATH wrapper from the app (see "Implemented additions" below). The app does not launch or control OpenCode processes.

## Current shell

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●   RelayDock                          [⟳ Test All]  [+ Import]  │
├──────────────────┬───────────────────────────────────────────────────┤
│ RelayDock        │ Overview                                          │
│ ⇄ Routing        │ Status                              ✓ Auto         │
│ ▦ Proxy Pool     │ Enabled                                      3    │
│                  │ Auto eligible                              2/3    │
│                  │ Healthy                                    1/3    │
│                  │                                                   │
│                  │ Policy                                            │
│                  │ Mode              [ Off ] [ Manual ] [ Auto ]     │
│                  │ Direct fallback                          [toggle] │
│                  │                                                   │
│ Edge · 1 active  │ RelayDock verifies traffic that routes through    │
│ v0.4.1           │ Edge; direct traffic stays invisible.             │
└──────────────────┴───────────────────────────────────────────────────┘
```

- The sidebar is navigation. The toolbar is actions. The app menu owns **Check for Updates…**.
- Update news appears as a detail-top banner only for available, downloading, ready, or failed phases.
- The menu bar panel keeps the same native controls at 360pt wide.


## Historical exploration

The variants below started from a Mos preferences screenshot: a compact Preferences window with centered title, horizontal icon-and-label tabs, then an aligned settings form. They assumed a top tab bar, no sidebar, and a 680×460 window. They are kept for history and no longer describe the shipped app.

- [Mos preferences screenshots](https://github.com/Caldis/Mos/tree/master/assets/readme/en-us)
- [Mos project README](https://github.com/Caldis/Mos/blob/master/README.enUS.md)

## Current constraints

- Native macOS window, **760×580 outer** by default (760×528 content under the unified toolbar), resizable; **680×500 content minimum**. Sidebar 180–240pt wide.
- The sidebar owns navigation; the toolbar owns **Test All** and **Import Proxies**; the app menu owns **Check for Updates…**.
- No account, usage, app settings, or server start/stop controls.
- A saved policy or successful endpoint check is not proof that OpenCode traffic used that route. The shipped honesty line is Edge-specific — "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible." — and appears in the Routing Policy footer, the Proxy Pool footer, and the menu bar panel's ⓘ popover.
- Only explicit Off allows direct routing. Manual/Auto errors must never be converted into Off silently.

The following variants are historical. The shipped direction is the native sidebar/detail shell described above.

## Variant A — Mos-style Preferences tabs

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●                         RelayDock                              │
│                                                                      │
│       [⇄ Routing]              ▦ Proxy Pool                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ROUTING                                                             │
│                                                                      │
│  Proxy Mode       [ Off ] [ Manual ] [ Auto ]                        │
│                                                                      │
│  Manual Proxy     [ gateway-east · east.example.net:8080       ▾ ]   │
│                   Only shown/enabled when Manual is selected.        │
│                                                                      │
│  Auto Pool        2 eligible · 4 enabled                             │
│                   Unchecked proxies may be eligible.                 │
│                                                                      │
│  Policy           Saved locally                                      │
│                 Verifies Edge-routed traffic; direct stays invisible. │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Proxy Pool tab:**

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●                         RelayDock                              │
│                                                                      │
│          ⇄ Routing          [▦ Proxy Pool]                            │
├──────────────────────────────────────────────────────────────────────┤
│  PROXY POOL · 4                              [Test All]  [ + Import ]│
│                                                                      │
│  gateway-east       east.example.net:8080       Passed · 42 ms  [On] │
│  backup-socks       socks.example.net:1080      Not tested      [On] │
│  gateway-west       west.example.net:8080       Disabled       [Off] │
│  local-debug        127.0.0.1:8888              Failed          [On] │
│                                                                      │
│  Select a row to reveal details and actions.                         │
│  Only Edge-routed traffic is verified; direct stays invisible.       │
└──────────────────────────────────────────────────────────────────────┘
```

This is closest to the screenshot you sent: icon tabs remain visible, the selected page uses straightforward form/list rows, and there is no navigation sidebar. The current MVP uses inline proxy details rather than a permanent inspector.

## Variant B — Split inspector

Best when proxy-by-proxy editing is frequent. It borrows the list/detail pattern from Mos's per-app settings screenshot, but is wider and less like the screenshot you shared.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ RelayDock          [Routing] [Proxy Pool]       [Test All] [+]        │
├──────────────────────────────────────────────────────────────────────┤
│ AUTO · 2 eligible             Policy saved · live traffic unverified │
├──────────────────────┬───────────────────────────────────────────────┤
│ PROXY POOL            │ gateway-east                    [Enabled] [⋯]│
│ > gateway-east        │ east.example.net:8080                         │
│   backup-socks        │ Last test  Passed · 42 ms · 2 min ago        │
│   gateway-west        │ Protocol   HTTP                              │
│   local-debug         │ Credentials Masked                           │
│                       │ [Test]  [Use as Manual]                       │
└───────────────────────┴───────────────────────────────────────────────┘
```

Suggested size: **700 × 460 pt**. The current row selection opens details; in Auto, that selection is only an inspector focus—not the route a future caller will use.

## Variant C — Single compact list

Best for the smallest standalone window. Selecting a row expands its details inline.

```text
┌──────────────────────────────────────────────────────────────┐
│ RelayDock       [Routing] [Proxy Pool]       [Test] [+]      │
├──────────────────────────────────────────────────────────────┤
│ AUTO · 2 eligible · live traffic unverified                  │
├──────────────────────────────────────────────────────────────┤
│ ▼ gateway-east    east.example.net:8080    Passed · 42 ms    │
│   HTTP · checked 2 min ago · credentials masked               │
│   [Test this proxy]                         [Use as Manual]   │
│   backup-socks    socks.example.net:1080    Not tested        │
│   gateway-west    west.example.net:8080     Disabled          │
└──────────────────────────────────────────────────────────────┘
```

Suggested size: **590 × 390 pt**. Very compact, but expanded details increase list height.

## Variant D — Menu-bar popover

An optional Mos-like utility pattern for frequent mode changes; it is not the Preferences-window pattern in your screenshot. Use only if RelayDock should primarily live in the menu bar.

```text
             ┌────────────────────────────────────┐
             │ RelayDock                           │
             │ [ Off ] [ Manual ] [ Auto ]         │
             │ AUTO · 2 eligible                   │
             │ Live traffic not verified.          │
             ├────────────────────────────────────┤
             │ gateway-east       Passed · 42 ms   │
             │ backup-socks       Not tested       │
             │ local-debug        Failed           │
             ├────────────────────────────────────┤
             │ [Test All] [+ Import] [Manage Pool…]│
             └────────────────────────────────────┘
```

Popover width: **360–400 pt**. Detailed management opens a regular window.

## Comparison

| Variant | Footprint | Best for |
|---|---:|---|
| **A — Preferences tabs** | 680 × 460 pt | Historical; closest match to the original Mos reference |
| **B — Split inspector** | 700 × 460 pt | Frequent detailed editing |
| **C — Inline list** | 590 × 390 pt | Smallest regular window |
| **D — Menu-bar popover** | 360–400 pt wide | Quick mode changes from the menu bar |

## Shared interaction and states

- The sidebar contains **Routing** and **Proxy Pool** only—no filler About/Updates item. The app menu owns update checking.
- **Routing:** Off explicitly permits direct routing; Manual requires one enabled, valid proxy; Auto shows enabled/eligible counts and fails closed when none is usable. The opt-in **Direct fallback** toggle (Manual/Auto only; off by default) turns that failure into a labeled, counted direct connection instead.
- **Proxy Pool:** the toolbar's **Test All** checks enabled entries, **Import Proxies** opens the import sheet, and each row shows text health state plus an enabled switch.
- Failed checks remain endpoint-check results, not proof about live OpenCode traffic; only Edge's tunnel accounting speaks to real traffic, and only to the traffic that routes through Edge. Unknown health is distinct from failed health.
- If Manual has no valid selection, keep the previous policy and prompt for a proxy. Never silently switch to Off.
- Preserve pasted import text after validation errors and show invalid line numbers; mask credentials in labels, previews, and errors.
- Use native controls in Light and Dark appearance and the user's system accent for interactive controls. Keep status monochrome and pair it with a label/symbol; expose sidebar selection, proxy health, and enabled state to VoiceOver, and keep keyboard focus order visible.

## Implemented additions (P2)

- **Routing page — advanced Edge section:** live daemon state (running / not running / not configured), mode, upstream with source and expiry, rotation and failure counters, a direct-fallback count when nonzero, provider cooldown, last error, and recent tunnels grouped by peer process (pid + name, active-first). Polled from Edge's `/__relaydock/status` roughly every 3 s while the window or the menu bar panel is visible; a miss reads as "not running", never as an error. Footnote: "From Edge's own tunnel accounting."
- **Proxy Pool — delegated `Test All`:** checks run inside Edge (`/check?scope=all`, available in every mode including Off) whenever `edge.json` exists and Edge answers. Checks probe the proxy each entry is currently serving — live upstream, pinned upstream, or the resolution its script cache holds — and never run a script, so `Test All` can neither rotate an exit nor surface the provider's change cooldown; an entry with nothing resolved yet is reported as skipped, not failed. When Edge is unreachable the check falls back in-process, follows the same probe rule, and the check-notes banner says so — "RelayDock Edge was unreachable, so the last check ran in this app." — or "Last check ran through RelayDock Edge." otherwise.
- **Proxy Pool — OpenCode free-limit pauses:** a `FreeUsageLimitError` reported by the loopback plugin pauses the entry that actually delivered the response, using the provider's reset window or the next 00:00 UTC when it sends none. In OpenCode 2.x the plugin then asks OpenCode to retry after 1.5 s once Edge has paused that entry and confirmed another eligible proxy is available (at most three attempts in total); Edge closes the delivering tunnel first so the retry reaches a different exit. Manual keeps its saved selection and only borrows the rest of the pool for the pause; pinned listeners never fail over, and an exhausted pool surfaces the error. The expanded row shows the absolute local reset time and a **Retry now** action; the entry stays paused unless a real probe passes. An automatic check runs at most once per cooldown, only in the 15 minutes before the reset. When two or more enabled entries have reset deadlines within 30 minutes of each other, a banner warns that the free limit is account/network-wide, so switching proxies will not restore access.
- **Menu bar panel and sidebar — Edge line:** the panel shows `Edge running · <upstream label | Direct | No upstream> · <N active>`, showing Edge's own mode only when it diverges from the saved one; `Edge not running` when the daemon does not answer (tooltip: starts on demand at the next wrapped launch). The sidebar footer condenses the same state to `Edge · N active`, `Edge not running`, or `Edge not set up`.
- **Honesty line (Routing Policy footer + Proxy Pool footer + panel ⓘ):** "RelayDock verifies traffic that routes through Edge; direct traffic stays invisible."

## Implemented additions (routing setup)

- **Routing page — advanced setup section** (inside the **RelayDock Edge & routing setup** disclosure, below Policy): not installed → the opt-in explanation, a primary **Install Routing**, and a "What it writes" disclosure listing every path the installer touches (`relaydock-launch`, `relaydock-edge`, the `opencode` symlink — never replacing a non-symlink `opencode` — the launchd agent plist, and `edge.json`). Installed → a **Login agent** row, a **New terminals** row that reports the login shell's own answer (`zsh -lic 'command -v opencode'`) after a **Verify** click — resolving to the wrapper is a checkmark; a miss or a shadowing path shows the copyable `export PATH="$HOME/.local/bin:$PATH"` snippet — a copyable `opencode service stop && opencode service start` hint, and **Uninstall…** behind a confirmation dialog that lists exactly what is removed (agent, both binaries, symlink, `edge.json`; the proxy pool and Edge's script cache stay). Components that differ from the app's build light an ink "Update Components" row; a missing agent offers "Repair Install". The app never edits shell profiles, nothing runs unprompted, and the standalone `scripts/opencode-wrapper.sh install` still covers source checkouts and headless machines.
- **Advanced Edge section — "not configured" caption:** now points at the setup rows ("Use the routing setup above to install it.") instead of the install script.

## Implemented refinements (menu bar panel)

- **State anchor:** the panel leads with the same symbol, ink weight, headline, and consequence line as the Routing page, from one shared source (`RoutingStatePresentation`) — a warning reads identically on both surfaces. Calm captions earn their line only when they inform: Manual's fail-closed promise, and Auto's "Unchecked proxies may be eligible." while an enabled proxy is unchecked.
- **Header:** no longer repeats the saved mode; the anchor and the segmented control already say it.
- **Row freshness:** rows append a compact check age (`· 2m ago`, `1h ago`, `2d ago`) when the health timestamp is in the stored millisecond format; legacy seconds timestamps and in-progress test runs show none. Row tooltips and VoiceOver labels carry outcome, error, and age (`ProxyStatus.detail`).
- **Chrome:** "Test All" gains a refresh glyph, the error banner's Dismiss is a link, the honesty line gains an info glyph, and panel padding uses the 12-point panel gutter.

## Shared components (native app design system)

The native shell comes from SwiftUI itself — `NavigationSplitView`, sidebar `List`, toolbar, grouped `Form`, inset `List`, `ContentUnavailableView`, sheets, and alerts. Only the small pieces below are shared app code (`Sources/RelayDockApp/AppComponents.swift` and `AppTheme.swift`); `AppChrome.swift` has been removed and must not be restored.

- **`AppLayout`:** panel gutter 12, sheet gutter 20, status-glyph size 13.
- **`AppActionRole` + `.appAction(_:size:)`:** maps to native button styles. `primary` is `.borderedProminent`, `secondary` is `.bordered`, and `link` is `.link`. The system accent drives all three. Sizes follow the surface; no custom button chrome.
- **`AppTheme`:** the remaining semantic tokens — `windowBackground`, `ink`, `inkMuted`, and `Motion.status` (0.16s ease-in-out for row glyph and counter changes). There is no app-specific card, topbar, pill, or button palette.
- **`ProxyHealthIcon` and `ProxyStatusText`:** the row glyph and the pass/fail/excluded copy with its optional "· 2m ago" age, shared by the pool window and the menu bar panel (`ProxyStatus` supplies the words and ink weights).
- **`VerificationInfoButton` and `AppCopy.verificationHonesty`:** the panel's ⓘ popover and the honesty line's one wording.

Action weights in place: toolbar — icon buttons for **Test All** and **Import Proxies**; panel — bordered "Test All" and prominent "Open RelayDock" as equal-width halves; sheets — bordered "Cancel" and prominent Add/Import/Save; empty states — one prominent call to action ("Import Proxies…").
