# App updates (design)

RelayDock updates itself from GitHub Releases. The goal: a user who installed
`RelayDock.app` once never has to download a new build by hand again.

## Flow

1. **Check** — on the first panel/window appearance per day, the app asks
   `GET /repos/nxhung1610/relaydock/releases/latest` (no auth, no proxy, no
   telemetry). “Check for Updates” in the panel footer ignores the throttle.
2. **Offer** — a strictly newer `vX.Y.Z` tag shows in the panel footer with a
   Release Notes link and an Update button. Nothing newer, nothing shown.
3. **Download + verify** — `RelayDock.app.zip` and `SHA256SUMS` are fetched
   over TLS; the archive is hashed (SHA-256), unpacked with `ditto`, and the
   staged bundle must prove: same bundle identifier, version equal to the
   release tag, executable present, `codesign --verify --strict` passes.
   Any failure aborts before the installed app is touched.
4. **Apply** — “Restart to Update” spawns the same binary in helper mode
   (`RelayDock --apply-update <staged> <target> <pid> <stagingRoot> <status>`),
   then quits. The helper waits for the GUI to exit, copies the staged bundle
   next to the target, renames the old app aside and the new one in (atomic
   renames, with rollback on failure), relaunches, and cleans up staging.
5. **Report** — the helper writes `update-status.txt` next to the config; the
   next launch surfaces a failed apply once, then clears it.

## Trust model (honest version)

- The anchors are: TLS to `api.github.com`, `SHA256SUMS` from the same
  release, and bundle validation. This equals the trust of downloading the zip
  by hand from the Releases page — it is not a signature-based chain of trust.
- Update traffic bypasses system proxies and Edge on purpose: it is
  control-plane and must not depend on the thing it updates.
- Releases are ad-hoc signed (not Developer ID/notarized), so `codesign`
  proves integrity and consistency, not Apple review. Downloads made by the
  app never carry the quarantine flag, so updated builds launch without a
  Gatekeeper prompt; the first manual install is unchanged.
- The updater refuses to act outside an installed `.app` bundle
  (translocation, read-only folders, dev builds) and says so in the panel
  instead of guessing.

## Failure modes

| Symptom | Behavior |
| --- | --- |
| Offline / GitHub down | automatic check stays silent; manual check shows the error + retry |
| Rate limited (403) | shows the HTTP status; retry later |
| Hash mismatch | refuses to install; message states nothing was installed |
| Not writable / translocated | refused up front with the fix (“Move to /Applications”) |
| Apply fails after quit | old app intact (rollback); failure shown on next launch |

## Scope

- v1 updates the **app only**. `relaydock-edge` / `relaydock-launch` keep the
  installer flow; a “CLI tools out of date” flow is a follow-up.
- No third-party dependencies; Foundation + CryptoKit only. Sparkle was
  rejected: it needs Developer ID/notarized distribution to be worth its
  complexity, and this project ships ad-hoc signed builds.
- The updater runs before SwiftUI in the same binary (`RelayDockMain`), so the
  helper has no windows, menus, or single-instance behavior.

## Testing

- Unit tests cover: version comparison, `SHA256SUMS` parsing, release JSON
  parsing, staging validation (wrong bundle id/version/signature rejected),
  swap + rollback, the helper protocol, the daily throttle, and failure
  surfacing.
- `RELAYDOCK_UPDATE_FEED` overrides the feed endpoint for dry runs.
- Release guard: CD fails a tag build when the tag does not match
  `Info.plist`’s `CFBundleShortVersionString` (bump the plist before tagging).

## Backlog

- ed25519 signature over `SHA256SUMS` (CI-signed, public key embedded in the app).
- Updating the CLI binaries from the app (Edge restart keeps the existing
  consent rule).
- Developer ID + notarization for a warning-free first install.
- Surface the update row in the window on every state, matching the panel.

## Release checklist (unchanged flow, one added step)

1. Bump `macOS/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`).
2. Merge to `main`.
3. `git tag vX.Y.Z && git push origin vX.Y.Z` — CD publishes DMG, app zip,
   CLI binaries, `SHA256SUMS`, after the tag/version guard passes.
