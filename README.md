# MenuShelf

A minimal menu bar manager (in the spirit of Hidden Bar, Bartender and Ice) for
**macOS 27 only**. Swift + AppKit, SwiftUI for the windows. Agent app
(`LSUIElement`), not sandboxed.

See [NOTES-macos27.md](NOTES-macos27.md) for how the macOS 27 menu bar works and
why hiding is done the way it is.

## Requirements

- macOS 27 (tested on 27.0.1, build 26A434).
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is not needed.

## Build and run

```bash
./scripts/build-app.sh
```

```bash
open /Applications/MenuShelf.app
```

The script:
- runs `swift build -c release`;
- assembles `build/MenuShelf.app` with `Support/Info.plist`;
- signs it (see Permissions);
- quits a running MenuShelf and installs the app to `/Applications`.

MenuShelf must run from `/Applications` (see How it works). Use
`CONFIG=debug ./scripts/build-app.sh` for a debug build, and `INSTALL=0` to
skip installing.

To see the debug output live, run the binary from a terminal instead of `open`:

```bash
/Applications/MenuShelf.app/Contents/MacOS/MenuShelf
```

Output also goes to `~/Library/Logs/MenuShelf.log` and the unified log
(subsystem `dev.menushelf.MenuShelf`).

## How it works

MenuShelf uses MenuBarAgent's own visibility restriction (a private macOS 27
API), so **macOS hides, shows and animates the real icons**. Details,
provenance and measurements: [NOTES-macos27.md](NOTES-macos27.md) §11.

- **Configure:** on first run, or right-click « → **Edit Layout…**,
  everything is shown with a thin divider next to MenuShelf's ». ⌘-drag the
  icons you want hidden to the left of the divider, then click the divider
  (or ») to finish.
- **Per app:** hiding works per app. An app is hidden only when *all* of its
  icons are left of the divider.
- **Show / hide:** click « to show the hidden icons in their real places
  (menus open under them, as usual). Click » to hide them again, or click
  anywhere outside the menu bar, or press Esc with no menu open.
- **While anything is hidden, macOS also hides:** Focus, the camera/mic
  indicator and Now Playing. Clicking the clock doesn't open Notification
  Center. Control Center works.
- **Must run from /Applications.** Elsewhere, macOS hides MenuShelf's own
  items too. `scripts/build-app.sh` installs it there.
- **No fallback:** if a macOS update removes the API, MenuShelf logs it and
  stops hiding.

### Debugging

Launch with `--debug` to accept commands from `scripts/debug.swift`. Build it
with `swiftc -o build/debug scripts/debug.swift`, then for example:
`build/debug state`, `build/debug hide com.example.app`,
`build/debug record name 1`. Never enable this in a normal launch: any local
process could send commands.

## Permissions

| Permission | Needed for | How |
| --- | --- | --- |
| Accessibility | Reading where icons are when you finish editing | Asked on first run. The Permissions window opens System Settings → Privacy & Security → Accessibility; you turn MenuShelf on there. Hiding itself needs no permission. |

MenuShelf never changes System Settings itself.

**Keep permissions across rebuilds:** create a self-signed code-signing
certificate (Keychain Access → Certificate Assistant → Create a Certificate…,
type Code Signing) named `MenuShelf Dev`. The build script picks up any
identity whose name starts with "MenuShel", or the one in `SIGN_IDENTITY`.
Without one the build is signed ad hoc, and macOS drops the Accessibility
grant on every rebuild.

## Layout

```
Package.swift                 SwiftPM package, one executable target
Support/Info.plist            Bundle Info.plist (LSUIElement, bundle ID)
scripts/build-app.sh          Builds, signs and installs to /Applications
scripts/debug.swift           Sends --debug commands to a running MenuShelf
Sources/MenuShelf/
  main.swift, AppDelegate.swift
  MenuBarAssertion.swift      Shim over MenuBarAgent's restriction (private API)
  Restriction.swift           Keeps one assertion alive; gapless swaps, retries
  ShelfController.swift       Chevron + divider items, edit mode, close rules
  MenuTracker.swift           On-screen windows (menus/popovers) via CGWindowList
  MenuBarEnumerator.swift     Menu bar items per app via Accessibility (on Done)
  AX.swift                    Accessibility helpers
  Onboarding.swift            Accessibility permission window
  DebugCommands.swift         --debug commands and a 60 fps bar recorder
  Log.swift                   Console / unified log / ~/Library/Logs output
```
