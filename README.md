# WinBar

A Windows 11 taskbar ("Combine taskbar buttons: Never") for macOS 26, Apple Silicon. It is a background agent app with no Dock icon and no menu-bar item. It is for personal use only: it is self-signed and not sandboxed, notarized or distributed.

Requirements: Swift 6.3 Command Line Tools (Xcode is not needed) and the macOS 26 SDK.

## One-time setup (per Mac)

1. **Move the Dock out of the way.** In System Settings → Desktop & Dock, set "Position on screen" to **Left** or **Right** and turn on **Automatically hide and show the Dock**. The bottom edge of every display belongs to WinBar. An auto-hidden Dock at the bottom would slide over the bar. The one exception is the "never appears" setup in [Optional: minimize toward the bar](#optional-minimize-toward-the-bar).
2. **Create the signing identity.** Run this in **Terminal.app**, not through Claude Code:
   ```sh
   ./scripts/make-cert.sh
   ```
   It creates the self-signed "WinBar Local Signing" code-signing identity in your login keychain. It asks for your login keychain password (hidden input) and shows a system dialog to trust the certificate. Because the identity is stable, permission grants survive rebuilds. The script is safe to re-run: it exits if the identity already exists. Check the result with:
   ```sh
   security find-identity -v -p codesigning
   ```

### Optional: minimize toward the bar

macOS's Dock draws the minimize animation and always aims it at the Dock. No setting or public API points it at another app, and uBar has the same limitation. So with the Dock on the side, minimized windows fly to the side.

To make windows shrink down into the bottom edge instead, hide the Dock at the bottom and stop it from ever appearing (the workaround uBar's developer recommends):

1. In System Settings → Desktop & Dock, set:
   - **Position on screen:** **Bottom**
   - **Automatically hide and show the Dock:** on
   - **Minimize windows using:** **Scale effect**
2. Stop the hidden Dock from ever appearing (in Terminal.app):
   ```sh
   defaults write com.apple.dock autohide-delay -float 1000 && killall Dock
   ```

Windows then shrink toward the bottom edge where WinBar sits. They land where the hidden Dock is, not on the window's own button.

This setup also works with the rest of WinBar:
- **Menus:** a hidden Dock doesn't reserve the bottom 74 pt, so right-click menus still open right on the bar.
- **Badges:** WinBar still reads them, because it reads them from the Dock even while the Dock is hidden.

You lose the Dock, but WinBar replaces it anyway. This trick hasn't been tested on macOS 26.

To undo it:
```sh
defaults delete com.apple.dock autohide-delay && killall Dock
```
Then move the Dock back to the side.

## Build, install and run

```sh
./scripts/build-app.sh
```

The script does the following:
1. Builds in release mode.
2. Assembles `.build/WinBar.app` and signs it with "WinBar Local Signing".
3. Quits any running copy.
4. Installs the app to `~/Applications/WinBar.app` and removes the build copy, so only one bundle with ID `local.winbar` exists.
5. Launches the app.

Any extra arguments are passed on to WinBar, for example `./scripts/build-app.sh --log-events`.

Always launch the installed app (with the script, or with `open ~/Applications/WinBar.app`). Do not run the binary directly from a terminal: macOS would check permissions against the terminal instead of WinBar.

To check the self-test of the pure logic (it exits before any UI, and a failure gives a non-zero exit status):

```sh
swift run WinBar --self-test
```

## Permissions

On first run, macOS asks for these permissions:

- **Accessibility** (required). WinBar prompts at launch. Enable WinBar in System Settings → Privacy & Security → Accessibility. WinBar notices the grant within about a second, without a relaunch. If access is revoked later, WinBar goes back to its "needs Accessibility access" state.
- **Screen Recording** (optional, for hover thumbnails). WinBar requests it once, after Accessibility is granted. Enable it in Privacy & Security → Screen & System Audio Recording. A grant may only take effect after WinBar relaunches. If you don't grant it, everything else still works.
- **Downloads folder** (optional, for download progress). macOS asks the first time WinBar looks at `~/Downloads`. If you deny it, download progress may not appear, or may appear on the frontmost app instead of the downloading one.

Rebuilding with `build-app.sh` keeps all of these grants, because the signing identity does not change.

## Event log (diagnostics)

Launch with `--log-events` to append millisecond-timestamped plain-text lines to:

```
~/Library/Logs/WinBar/events.log
```

The file is cleared at each launch and removed when WinBar starts without the flag. It contains window titles and app names in clear text. To read it:

```sh
./scripts/build-app.sh --log-events
tail -f ~/Library/Logs/WinBar/events.log
```

The log is a file rather than the unified log for two reasons: the Claude Code sandbox blocks `/usr/bin/log`, and zsh has its own built-in `log` command.

## Claude Code sandbox note

SwiftPM only works outside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package` and `./scripts/build-app.sh` from the sandbox. The exclusion only applies when the whole command is one of these, so don't pipe or chain them (no `|`, `&&` or `cd … &&`). `make-cert.sh` is interactive, so run it in Terminal.app.

## Copying to another Mac

You have two options:

- **Build it there (recommended).** Clone the repository, then run `./scripts/make-cert.sh` (in Terminal.app) and `./scripts/build-app.sh`.
- **Copy the app.** Copy `~/Applications/WinBar.app` to the other Mac's `~/Applications`, clear the quarantine attribute, then open it:
  ```sh
  xattr -dr com.apple.quarantine ~/Applications/WinBar.app
  open ~/Applications/WinBar.app
  ```
  The other Mac does not trust this Mac's certificate. Permissions granted there may need re-granting after you copy a new build.

On each Mac, also move the Dock to the side (setup step 1) and grant the permissions.
