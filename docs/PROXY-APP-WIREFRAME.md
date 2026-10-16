# RelayDock proxy app — wireframe variants

**Status:** implemented as the initial config-only SwiftUI app. The figures below remain the design reference; the shipped MVP does not launch or control OpenCode processes.

## Reference

The attached Mos screenshot shows a compact Preferences window: centered title, a horizontal row of icon-and-label tabs, then a simple aligned settings form. **Variant A below follows that structure.** Mos's per-app screenshot also has a list/detail arrangement; that remains an alternative, not the primary direction.

- [Mos preferences screenshots](https://github.com/Caldis/Mos/tree/master/assets/readme/en-us)
- [Mos project README](https://github.com/Caldis/Mos/blob/master/README.enUS.md)

Borrow the information hierarchy and native macOS density—not Mos's colors, icons, branding, or custom appearance. RelayDock has one domain, so use only two meaningful tabs and no sidebar.

## Shared constraints

- Compact native macOS window, suggested **680 × 460 pt**, resizable; target a usable minimum near **600 × 400 pt**.
- Tabs are top-aligned icon + label controls. The Routing page owns Off/Manual/Auto; the Proxy Pool page owns import and tests.
- No account, usage, app settings, or server start/stop controls.
- A saved policy or successful endpoint check is not proof that OpenCode traffic used that route. Keep that distinction visible on both tabs.
- Only explicit Off allows direct routing. Manual/Auto errors must never be converted into Off silently.

## Variant A — Mos-style Preferences tabs (recommended)

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
│                   Live OpenCode traffic is not verified.             │
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
│  Health checks do not verify OpenCode traffic.                       │
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
| **A — Preferences tabs** | 680 × 460 pt | Closest match to your Mos screenshot; recommended starting point |
| **B — Split inspector** | 700 × 460 pt | Frequent detailed editing |
| **C — Inline list** | 590 × 390 pt | Smallest regular window |
| **D — Menu-bar popover** | 360–400 pt wide | Quick mode changes from the menu bar |

## Shared interaction and states

- The top tab row contains **Routing** and **Proxy Pool** only—no filler About/Updates tab.
- **Routing:** Off explicitly permits direct routing; Manual requires one enabled, valid proxy; Auto shows enabled/eligible counts and fails closed when none is usable.
- **Proxy Pool:** `Test All` checks enabled entries, `+ Import` opens a multiline import sheet, and each proxy shows text health state plus enabled state.
- Failed checks remain endpoint-check results, not proof about live OpenCode traffic. Unknown health is distinct from failed health.
- If Manual has no valid selection, keep the previous policy and prompt for a proxy. Never silently switch to Off.
- Preserve pasted import text after validation errors and show invalid line numbers; mask credentials in labels, previews, and errors.
- Use Aqua/system colors and controls in Light and Dark appearance. Pair color with a label/symbol, expose tab and control states to VoiceOver, and keep keyboard focus order visible.
