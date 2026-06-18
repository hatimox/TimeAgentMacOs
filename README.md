# TimeAgentMac

A **native macOS (SwiftUI + AppKit)** rewrite of TimeAgent — a menu-bar app that
logs meeting and task time to **TargetProcess**. Built to avoid the Electron
event-loop fragility (wedged JS timers, spawned `michelper` subprocesses) that
caused the meeting-detection freezes: here, microphone detection is a direct
in-process **CoreAudio** query and everything runs on native `NSStatusItem` /
`Timer` / `URLSession`.

It reuses the **same config and Keychain token** as the Electron app
(`~/Library/Application Support/TimeAgent/settings.json` +
`net.omnevo.timeagent`/`tp-token`), so it picks up your existing setup.

## Features (parity target)

- Menu-bar popover: signed-in user, **In meeting** indicator, today/week/month totals.
- Meeting detection via CoreAudio (no subprocess); end-of-meeting prompt
  **Daily / Defined list / Choose task / Cancel**.
- **Split** and **Stop tracking** controls while in a call.
- Task & Bug list: search, active-only filter, current-sprint/all scope,
  per-item **status change**, parent **US link**, hours total, direct logging,
  and **edit/delete** of individual time entries.
- Settings: TP URL + token, meeting task ids/rounding, recurring entries,
  dynamic meeting shortcuts.

## Build & run

```bash
swift build            # compile
swift run              # launch (menu-bar app; look for the clock icon)
# or
.build/debug/TimeAgentMac
```

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools).

## Packaging & distribution

Build a double-clickable, universal (Apple Silicon + Intel) `.app` and a `.dmg`:

```bash
VERSION=1.0.0 ./scripts/package.sh
# → dist/TimeAgent.app  and  dist/TimeAgent-1.0.0.dmg
```

The bundle is **ad-hoc signed, not notarized**, so the first launch needs
right-click → **Open** (or `xattr -dr com.apple.quarantine TimeAgent.app`).

**A `.app` vs a `.dmg`:** the `.app` is the application itself; the `.dmg` is a
disk-image wrapper you distribute — users open it, drag **TimeAgent** onto the
**Applications** shortcut, and that's the install.

### CI/CD (GitHub Actions)

- **`.github/workflows/ci.yml`** — on every push/PR: builds debug + universal
  release and packages the bundle as a smoke test, uploading the `.app` as a
  workflow artifact.
- **`.github/workflows/release.yml`** — on pushing a `v*` tag (e.g. `v1.0.0`):
  builds the universal `.app`, makes a `.dmg` + `.zip`, and publishes them to a
  GitHub Release. Cut a release with:

  ```bash
  git tag v1.0.0 && git push origin v1.0.0
  ```

  (Or run the workflow manually via *Actions → Release → Run workflow* with a
  version input.) Notarization would need Apple Developer secrets added to the
  repo — see the signing step in `scripts/package.sh` for where to hook it in.

## Status

This is a first full-parity scaffold: it compiles and runs as a menu-bar app
with the core flows wired end-to-end against the TP REST API. The CoreAudio
detection, TP client (with the noon-anchored date logic), status changes, time
edit/delete, meeting prompt, and **recurring auto-logging** (once per working
day, skipping weekly days off + Morocco holidays, deduped via
`recurring_logged.json`) are functional. The Settings → **Days off** tab manages
region, weekly off, specific days off, and the editable religious-holiday
estimates.

Packaging into a universal, double-clickable `.app`/`.dmg` is done (see above),
with GitHub Actions CI on every push and a tag-driven release workflow. Still
not ported from the Electron app: auto-update, and signing/notarization (the
build is currently ad-hoc signed only).
