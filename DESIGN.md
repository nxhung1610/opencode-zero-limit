# RelayDock design

## Direction

A calm, precise native macOS utility for proxy configuration—not a browser dashboard or an OpenCode process manager. Keep the small window focused on two jobs: choosing a saved routing policy and maintaining a tested proxy pool.

## Navigation and composition

- Use the compact Preferences-style window with two icon-and-label tabs: **Routing** and **Proxy Pool**.
- Keep Off/Manual/Auto and their readiness context on Routing. Keep import, endpoint checks, enable/disable, and proxy details on Proxy Pool.
- Use a native grouped `Form`, standard list rows, native sheets, alerts, and confirmation dialogs.
- Do not add account, usage, quota, server start/stop, or general settings pages.
- Preserve a usable minimum window size and native resizing behavior.

## Color and typography

- Use semantic SwiftUI colors and the system accent color; support system Light and Dark appearance.
- Pair color with a visible text label and/or symbol for proxy health and routing state.
- Use system typography; reserve monospaced text for technical values such as proxy endpoints.
- Avoid gradients, heavy shadows, glass effects, and custom surfaces that fight Aqua window chrome.

## Interaction and safety

- Prefer standard buttons, toggles, pickers, text editors, alerts, and confirmation dialogs.
- Expose selected tabs, proxy health, and enabled state to VoiceOver; keep keyboard focus and hit targets clear.
- Retain import text after validation errors and identify invalid lines.
- Mask proxy credentials in labels, previews, and copy actions.
- Manual/Auto errors must never silently become Off. A saved setting and a successful endpoint check do not verify live OpenCode traffic; say so in the UI.

## Brand assets

Use the existing RelayDock icon as the source of truth. Do not alter the mark without explicit approval.
