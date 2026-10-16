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

## How v1 works

- **Hiding:** MenuShelf adds a divider status item and sizes it so macOS
  pushes it, and every icon to its left, into the menu bar's native overflow.
  No permission is needed for this.
- **Configuring:** on first run, or via right-click → **Edit Layout…**, the
  divider becomes a visible line. ⌘-drag icons to its left to hide them,
  then click **Done**.
- **One arrow:** macOS shows its own « overflow arrow. MenuShelf sits an
  invisible window on top of it, so clicking it opens MenuShelf's panel
  instead of macOS's expansion.
- **Revealing:** the hidden icons slide into the empty part of the bar with
  a light spring and fade. Click one to open its menu. Click anywhere else,
  or the arrow, to close.
- **Right-click the arrow** for Edit Layout, Refresh Item Images,
  Permissions, Diagnostics and Quit.

Limits and evidence: [NOTES-macos27.md](NOTES-macos27.md) §10. Hiding works
on displays with a notch. Wide external displays show everything.

### Launch flags

| Flag | Effect |
| --- | --- |
| *(none)* | MenuShelf v1 |
| `--debug` | Accept commands from `scripts/spike.swift` (`build/spike snap`, `open`, `press 2`, …) |
| `--legacy` | First prototype: own chevron, per-app VisibleCC hiding, list window |
| `--spike` | Legacy + the spacer spike tooling (NOTES §8–9) |

## Self-test

```bash
.build/release/MenuShelf --selftest
```

This runs the hiding logic against a throwaway defaults domain
(`dev.menushelf.selftest-target`). It touches no real app and needs no
permissions.

## How hiding works (experimental)

macOS 27 removed the per-item windows the old tricks relied on. Thaw's
bar-wide hiding uses a closed binary, so MenuShelf uses the one open
mechanism: AppKit's per-item switch `NSStatusItem VisibleCC <autosaveName>`
in the owning app's preferences, which System Settings also writes. Marking
an app Hidden sets it to false for each of the app's items, and the
original values are saved so revealing restores them exactly.

- Only works for non-sandboxed apps. Apple's items are left alone.
- An app may need a relaunch to pick up the change. Settings and the menu
  offer **Relaunch**, and only do it when you click it.
- Quitting MenuShelf restores every app it hid.

Details and what is still unverified: [NOTES-macos27.md](NOTES-macos27.md).

## Permissions

| Permission | Needed for | How |
| --- | --- | --- |
| Accessibility | Finding hidden icons and the arrow, opening icons from the panel | **Required.** The Permissions window opens System Settings → Privacy & Security → Accessibility; you turn MenuShelf on there. |
| Screen Recording | Real icon images in the panel | Optional. Without it the panel shows app icons. Captures happen only when you finish editing the layout. |

MenuShelf never changes System Settings itself.

**Keep permissions across rebuilds:** create a self-signed code-signing
certificate (Keychain Access → Certificate Assistant → Create a Certificate…,
type Code Signing) named `MenuShelf Dev`, or pass its name in
`SIGN_IDENTITY`. Without it the build is signed ad hoc, and macOS drops both
grants on every rebuild: remove MenuShelf with **–** in each list and add it
again.

## Using the legacy prototype (`--legacy`)

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
  Shelf/                      v1: HidingSpacer, ArrowCatcher, RevealPanel,
                              ItemImageCache, BarReader, ShelfController
  Hiding.swift                VisibleCC hiding backend (legacy only)
  SelfTest.swift              --selftest for the hiding backend
  Log.swift                   Console / unified log / ~/Library/Logs output
  StatusItemController.swift  The chevron status item and its menu
  SettingsView.swift          Settings window
  Onboarding.swift            Accessibility onboarding window
```
