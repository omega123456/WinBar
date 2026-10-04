# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

WinBar is a Windows 11 taskbar ("Combine taskbar buttons: Never") for macOS 26 on Apple Silicon. It is an `LSUIElement` agent app (`local.winbar`) for personal use only: self-signed, not sandboxed, never notarized or distributed. It is a single SwiftPM executable target that uses system frameworks only, built with the Swift 6.3 Command Line Tools. The only dependency is swift-snapshot-testing, used by the test target alone; tests run with Xcode's toolchain via `scripts/test.sh`. `Package.swift` pins Swift language mode v5.

## Commands

```sh
swift build                    # debug build (compile check)
swift run WinBar --self-test   # pure-logic checks; exits before any UI, non-zero on failure
./scripts/test.sh              # snapshot tests + SelfTest (Tests/WinBarTests), offscreen; extra args go to swift test (--filter …)
./scripts/coverage.sh          # test.sh with LLVM line coverage of Sources/WinBar; fails below COVERAGE_MIN (default 90); COVERAGE_HTML=1 → .build/xcode/coverage/index.html
./scripts/build-app.sh         # debug "WinBar Dev" build → sign → quit running WinBar (prod too) → install to ~/Applications → launch
./scripts/build-app.sh --log-events   # extra args are passed to WinBar
tail -f ~/Library/Logs/WinBar\ Dev/events.log
pkill -x WinBarDev; open /Applications/WinBar.app   # back to production
./scripts/release.sh            # (user runs it) bump Info.plist version, verify, commit, tag vX.Y.Z, push → .github/workflows/release.yml
```

- **Sandbox:** SwiftPM fails inside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package`, `./scripts/build-app.sh`, `./scripts/test.sh` and `./scripts/coverage.sh`, but only when the command is exactly one of these. Don't pipe, chain or prefix them (`|`, `&&`, `cd … &&`).
- **Two suites.** `--self-test` covers the pure logic and needs only the CLT. To add coverage, add a `check(...)` in `Sources/WinBar/SelfTest.swift`. It counts failures explicitly, because `assert` is compiled out of release builds. `Tests/WinBarTests/SelfTests.swift` also runs it under `swift test`, so coverage counts it. `SelfTest.swift` itself is excluded from the coverage total.
- **Snapshot tests** (`Tests/WinBarTests`, Swift Testing + swift-snapshot-testing) render views offscreen with `CALayer.render(in:)` and compare them with the PNGs in `__Snapshots__`. Nothing is shown on screen and no TCC grant is needed.
  - **Toolchain:** the library imports XCTest, which only Xcode ships. So `scripts/test.sh` runs `swift test` with `DEVELOPER_DIR` set to Xcode (Swift 6.4) and its own `.build/xcode` scratch path. `xcode-select` stays on the CLT (6.3.1) for app builds. Xcode's license must be accepted, which needs sudo, so the user runs it.
  - **Coverage:** `TaskbarButtonSnapshotTests` has one parameterized test over 14 states. They are the window, active, icon-only, launcher, app item and overflow buttons; the 4 badges; progress and paused progress; attention; and a long title. References are named `TaskbarButton.<case>.png`. To add a state, add a `Case` and its `content`.
  - **Determinism:** tests register the bundled Selawik fonts themselves. Without that, `Fonts.label` silently falls back to SF. They use `Theme()`, never `Theme.current()`, and an icon drawn in code, so renders don't depend on system settings or the macOS version.
  - **Comparison:** `precision: 0.99`, `perceptualPrecision: 0.98`. A 2 pt badge shift fails exactly the affected cases. On a mismatch the new image is written to `$TMPDIR/TaskbarButtonSnapshotTests/` for comparison.
  - **Re-recording:** the first run of a new case records its PNG and reports a failure. Delete a PNG to re-record it, then always check the new image by eye before committing.
  - **Not covered:** the acrylic material. It doesn't render offscreen, so don't snapshot it (see the acrylic ADR).
  - **CI:** tests aren't run there yet. The references were recorded on the owner's Mac and may differ on the `macos-26` runner.
  - **Package.resolved:** the CLT and Xcode resolve `xctest-dynamic-overlay`, now renamed `swift-issue-reporting` (same repo), differently. If `Package.resolved` keeps changing between the two toolchains, pin it.
- **Desktop tests** (`Tests/WinBarTests`, suite `Desktop`, serialized) drive the real tracker, signals, bars, preview, click tap, app delegate and updater with fakes behind test seams. Nothing touches the real desktop, apps, defaults, network or TCC.
  - **Seams:** `Env.workspace/screens/defaults`, `AX.backend` (every AX C call, plus trust), `WindowTracker.onScreenWindowIDs/managedDisplaySpaces`, `BarController.trackMenu`, `PreviewController.checkPermission/captureWindow`, `Signals.downloadsFolder/pidOfASN`, and `Updater.isInstallable/bundleURL/notice/ask/verify/relaunch`. Production never reassigns them. New code that reaches outside the process goes through `Env` or a seam like these.
  - **Fakes** (`Fakes.swift`): offscreen `FakeScreen`s (bars at x −20000), `FakeApp`, `FakeWorkspace` with its own notification center, an in-memory `FakeAX`, and `Harness`, which installs everything fresh per test. The network is stubbed with a `URLProtocol` (`UpdaterTests`).
  - **Async:** a `@MainActor` test waits with `await settle(seconds)`, which lets main-queue flushes and timers run. A nested run-loop spin does not drain the main queue.
  - **Don't** call `NSButton.performClick` in tests: it stops the main run loop, and the runner then exits 0 mid-run. Send the action instead.
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
