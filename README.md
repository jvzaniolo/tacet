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
open build/MenuShelf.app
```

The script runs `swift build -c release`, puts the binary in
`build/MenuShelf.app` with `Support/Info.plist`, and signs it ad hoc. Use
`CONFIG=debug ./scripts/build-app.sh` for a debug build.

To see the debug output live, run the binary from a terminal instead of `open`:

```bash
build/MenuShelf.app/Contents/MacOS/MenuShelf
```

Output also goes to `~/Library/Logs/MenuShelf.log` and the unified log
(subsystem `dev.menushelf.MenuShelf`).

## Permissions

| Permission | Needed for | How |
| --- | --- | --- |
| Accessibility | Listing other apps' menu bar items, opening them | Required. MenuShelf shows a window with a button that opens System Settings → Privacy & Security → Accessibility; you turn MenuShelf on there. |

MenuShelf never changes System Settings itself.

**Ad-hoc signing caveat:** macOS ties an ad-hoc signed app's Accessibility grant
to the exact binary. After a rebuild, the switch in System Settings may still
look on but no longer apply. Turn MenuShelf off and on again (or remove it with
**–** and re-add it) after each rebuild. Signing with a stable Developer ID
certificate avoids this.

## Using it

- **Left-click** the chevron: show or hide the apps you marked Hidden.
- **Right-click** (or control-click) the chevron: menu with the Hidden apps and
  their items (pick one to open it), **Settings…** and **Quit**.
- **Settings…**: every app that owns menu bar items, grouped by app (icon, name,
  bundle ID, items with position and AX identifier). The **Hidden** switch is
  per app and is saved by bundle ID. **Dump to Console** writes the full list to
  the log.

## Layout

```
Package.swift                 SwiftPM package, one executable target
Support/Info.plist            Bundle Info.plist (LSUIElement, bundle ID)
scripts/build-app.sh          Builds build/MenuShelf.app
Sources/MenuShelf/
  main.swift, AppDelegate.swift
  AX.swift                    Accessibility helpers
  MenuBarEnumerator.swift     Lists menu bar items per app via AXExtrasMenuBar
  AppModel.swift              Scan results, Hidden set, revealed state
  Hiding.swift                Hiding backends
  StatusItemController.swift  The chevron status item and its menu
  SettingsView.swift          Settings window
  Onboarding.swift            Accessibility onboarding window
```
