# RelayDock proxy app plan

## Target

A small native macOS app for managing a local proxy pool and Off/Manual/Auto policy, backed by a reusable Swift core. This MVP is config-only: it does not launch or control OpenCode, and it does not claim that any OpenCode process uses the saved proxy.

## Implemented

- Native SwiftUI app target with Routing and Proxy Pool Preferences-style tabs.
- Proxy import, masked display, enable/disable, removal, health checks, and local persistence.
- Off, Manual, and Auto policy controls with explicit Manual selection and fail-closed behavior.
- Clear UI distinction between saved policy, proxy endpoint health, and unverified live OpenCode traffic.
- Reusable `RelayDockCore` selection and child-process environment helpers.
- App-model and core regression tests.
- App bundle build script and macOS CI validation.

## Follow-up

1. Perform visual, keyboard, and VoiceOver QA on a real macOS window in Light and Dark appearance.
2. Verify the app bundle on macOS 14; add signing/notarization only when a distribution path is chosen.
3. If a future product direction manages OpenCode processes, first design and verify how the selected client consumes proxy environment variables. Do not infer active routing from configuration or health checks.

Former account/login, usage, quota, unrelated settings, and process-management behavior is archived in `docs/REMOVED-FEATURES.md`; it is not part of this proxy-only app.
