# Removed app features (historical reference)

This is an archive of behavior from the former full-featured RelayDock app. The current package contains a proxy-only SwiftUI app and `RelayDockCore`; it does not include account, login, usage, quota, or general app-settings features.

## Accounts and login

- The former app used OpenCode v2 Console OAuth. A user could begin an authorization attempt, open the provider's verification URL, poll or enter a code, and then list, activate, or remove saved connection metadata.
- For OpenCode v1, the former app could list organizations and switch the active organization as part of its account controls.
- RelayDock did not read or store OpenCode credential values; the OpenCode CLI owned its local credential store. The account UI and OAuth request/polling code have been removed.

## Usage

The former app read local OpenCode SQLite data and summarized observed messages, sessions, tokens, costs, models, and active-account context. It did not claim to know an exact remaining quota. The usage reader and UI have been removed.

## Quota recovery

The former app observed supported quota-related events from a managed OpenCode event stream. Optional rotation could switch to another saved v2 credential or v1 organization, subject to supported events and a cooldown. Quota monitoring, rotation, and account-store integration have been removed.

## App and settings

The former native app managed an `opencode serve` child process and exposed auto-start, auto-rotation, binary-path, appearance, and legacy-wrapper controls. Those process, settings, and related UI implementations are removed. The current proxy-only app does not start or stop OpenCode.

## Data note

Removing these source files does not delete local OpenCode credentials, SQLite databases, or existing RelayDock settings. The proxy app and core continue to use the established `proxies.json` path by default. This archive does not provide an operational way to use the removed features.
