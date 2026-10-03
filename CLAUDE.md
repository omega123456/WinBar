# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

WinBar is a Windows 11 taskbar ("Combine taskbar buttons: Never") for macOS 26 on Apple Silicon. It is an `LSUIElement` agent app (`local.winbar`) for personal use only: self-signed, not sandboxed, never notarized or distributed. It is a single SwiftPM executable target that uses system frameworks only (no dependencies), with Swift 6.3 Command Line Tools and no Xcode. `Package.swift` pins Swift language mode v5.

## Commands

```sh
swift build                    # debug build (compile check)
swift run WinBar --self-test   # pure-logic checks; exits before any UI, non-zero on failure
./scripts/build-app.sh         # debug "WinBar Dev" build → sign → quit running WinBar (prod too) → install to ~/Applications → launch
./scripts/build-app.sh --log-events   # extra args are passed to WinBar
tail -f ~/Library/Logs/WinBar\ Dev/events.log
pkill -x WinBarDev; open /Applications/WinBar.app   # back to production
./scripts/release.sh            # (user runs it) bump Info.plist version, verify, commit, tag vX.Y.Z, push → .github/workflows/release.yml
```

- **Sandbox:** SwiftPM fails inside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package` and `./scripts/build-app.sh`, but only when the command is exactly one of these. Don't pipe, chain or prefix them (`|`, `&&`, `cd … &&`).
- **No test framework** (XCTest isn't available with CLT only). `--self-test` is the whole suite and can't run a single check. To add coverage, add a `check(...)` in `Sources/WinBar/SelfTest.swift`. It counts failures explicitly, because `assert` is compiled out of release builds.
- **Dev vs production:** production is `/Applications/WinBar.app` (`local.winbar`, from the DMG, self-updating). `build-app.sh` builds **WinBar Dev**: a debug build with bundle ID `local.winbar.dev` and executable `WinBarDev`, so UserDefaults, the login item and TCC grants are separate. Dev-only behaviour is gated by `#if DEBUG` (no updater, its own log folder). `BUNDLE_ONLY=1` (CI) builds the production release bundle.
- **Never run the binary directly** (`.build/.../WinBar`) for real use. TCC would check permissions against the terminal. Launch the installed app with the script or `open ~/Applications/WinBar\ Dev.app`.
- `scripts/make-cert.sh` is interactive (keychain password, trust dialog). The user runs it in Terminal.app, not you. It creates the "WinBar Local Signing" identity, which keeps the Accessibility and Screen Recording grants valid across rebuilds.
- `--log-events` writes to a file because the sandbox blocks `/usr/bin/log`. The log holds window titles in clear text.

## Architecture

All work runs on the main thread and is event-driven. The data flows one way:

```
NSWorkspace / distributed notifications / per-app AXObservers
        │ (one-shot ~50 ms coalescing flush)
        ▼
WindowTracker ── single source of truth: apps, windows, display assignment, session + MRU order
Signals ──────── per-app badge (Dock AX, 2 s poll), download progress (~/Downloads NSProgress), attention (LaunchServices SPI)
        │ onChange
        ▼
BarController ── one TaskbarPanel per display; composes BarItems (pinned slots, app items, launchers, windows),
        │        width fitting / "…" overflow, click and menu actions, drag reorder, pin persistence (UserDefaults)
        ▼
TaskbarPanel → TaskbarButton (layer-backed, diffed by ItemKey, updated property by property, never rebuilt)
PreviewController ── single shared hover-preview panel, ScreenCaptureKit one-shot capture + LRU cache
```

`AppDelegate` (`App.swift`) wires these together and gates everything on Accessibility trust. While untrusted it polls every 1 s and the bar shows a call to action. When trust arrives it installs `BarClickTap` and starts the tracker and signals.

Cross-cutting rules that need several files to see:

- **WinBar must never become active.** On macOS 26 a click on any window activates its app, even a `.nonactivatingPanel`. So mouse-downs on bars and the preview are taken from a CGEvent tap (`BarClickTap` in `TaskbarPanel.swift`) and delivered directly. Menu items are fired from the tap too. Window focusing uses AX (`AXFrontmost`/`AXMain`/`AXRaise`), never `NSRunningApplication.activate`.
- **Pure logic is kept as `static func`s** (`BarController.compose/fit/menuLocation/pinOrder`, `WindowTracker.cocoaRect/displayIndex/isVisible/clampedAboveBar`, `Signals.aggregate/attribute/attention/quarantineAgent`, `Badge(dockLabel:)`) so `SelfTest` can cover them without UI. New decision logic follows this pattern.
- **AX access goes through `AX.swift`.** Reads return nil on ordinary failures and throw only `AXFailure`. The first timeout abandons the rest of that app's reads for the current flush or tick. The global AX messaging timeout is 0.25 s.
- **Private APIs are resolved with `dlsym` and degrade gracefully.** `_AXUIElementGetWindow` is required: without it the bar shows "incompatible". The LaunchServices attention SPI (code 563) is optional: without it attention is disabled.
- **Idle cost:** the only periodic timers while idle are the 2 s badge poll and the hourly update check (`Updater.swift`, GitHub Releases of `omega123456/WinBar`). Animations run only while their signal is shown.
- **Coordinates:** AX uses top-left global coordinates and Cocoa uses bottom-left. Convert with `WindowTracker.cocoaRect(fromAX:primaryHeight:)`.
- Code comments cite "requirement N" and "Design decision N". These refer to `.agent/plans/2026-10-03_winbar_plan.md`, which holds the full spec, the wireframes and the reasons behind the measured constants. Its mockup is in `.agent/plans/assets/`.

## Architectural decisions (binding)

`.agent/adr/` is an append-only decision ledger, governed by `.agent/ADR_POLICY.md`. Never edit or delete an existing ADR. To reverse one, write a new ADR with a `## Relationship to previous decisions` section. Read the relevant ADR before you change:
- click delivery or menus (event tap)
- maximized-window clamping above the bar (AX resize)
- theming (single Win11 dark theme)
- the acrylic material (blend-mode layers over `NSVisualEffectView`)

## Verifying UI behaviour

Visual constants (materials, font smoothing, menu offsets) were calibrated by measuring the screen, not by reading layer dumps. Probing techniques and their limits are in `.claude/agent-memory/dev-workflow-phase-implementer/` (`verification-techniques.md`, `verification-limits.md`):
- `screencapture` and CGEvent work only with the sandbox disabled.
- The owner keeps using the desktop meanwhile, so only click test windows you created.
- lldb breakpoints don't fire here.
