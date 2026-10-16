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

Running from `/Applications` is no longer required (it was for the old
restriction), but it is where the app lives. Use
`CONFIG=debug ./scripts/build-app.sh` for a debug build, and `INSTALL=0` to
skip installing.

To see the debug output live, run the binary from a terminal instead of `open`:

```bash
/Applications/MenuShelf.app/Contents/MacOS/MenuShelf
```

Output also goes to `~/Library/Logs/MenuShelf.log` and the unified log
(subsystem `dev.menushelf.MenuShelf`).

## How it works

MenuShelf hides apps with the **"Allow in the Menu Bar" switches** of System
Settings › Menu Bar. macOS does the hiding and the animation, so Notification
Center, Focus, the camera/mic indicator and Now Playing keep working. Details
and measurements: [NOTES-macos27.md](NOTES-macos27.md) §12–13.

- **Choose apps:** right-click the arrow › **Settings…**. Every app macOS lists
  under "Allow in the Menu Bar" has a switch; switch an app off to hide it.
  Apps appear after their first time in the menu bar.
- **Show / hide:** click « to show the hidden apps in their real places (menus
  open under them, as usual). Click », anywhere outside the menu bar, or Esc
  with no menu open (Esc only if MenuShelf has Accessibility, which it doesn't
  ask for) to hide them again. Right-click › **Show All** keeps them shown.
- **Three states:** Visible, Hidden (by MenuShelf), and Off in System Settings
  (turned off outside MenuShelf: listed, never turned on by «). Changes made in
  System Settings are respected: turning a hidden app on there makes it
  Visible, turning a hidden app off there makes it Off in System Settings.
- **Hidden apps show as off in System Settings.** If anything goes wrong,
  turn them back on there.
- **Quitting restores:** Quit (or `kill`, logout) turns every app MenuShelf hid
  back on. Quit MenuShelf before deleting it. After a crash, the journal
  (`~/Library/Application Support/MenuShelf/journal.plist`) lets the next
  launch pick the hidden apps up again.
- **Speed tip (optional):** ⌘-drag your hidden apps to the left end of the
  menu bar. Then they fade in and out quickly (~0.15 s); elsewhere the icons
  next to them slide over (~0.45 s).

## Permissions

| Grant | Needed for | How |
| --- | --- | --- |
| Access to `group.com.apple.controlcenter.plist` | Reading and changing the switches (both need it: cfprefsd enforces the group-container protection, NOTES §13) | One-time open panel in onboarding; MenuShelf keeps a security-scoped bookmark. Full Disk Access would also work. |

No TCC permission (Accessibility, Screen Recording) is needed. MenuShelf never
changes System Settings itself beyond the switches of the apps you hide.

**Signing:** the build script signs with any code-signing identity whose name
starts with "MenuShel" (or `SIGN_IDENTITY`), else ad hoc.

## Layout

```
Package.swift                 SwiftPM package, one executable target
Support/Info.plist            Bundle Info.plist (LSUIElement, bundle ID)
scripts/build-app.sh          Builds, signs and installs to /Applications
Sources/MenuShelf/
  main.swift, AppDelegate.swift   Launch, quit-time restore, signal handling
  MenuBarSwitches.swift       Reads/writes the switches (private CF calls) + access
  ShelfModel.swift            Hidden apps, three states, reconcile, journal
  ShelfController.swift       The arrow, its menu and the close rules
  SettingsWindow.swift        Welcome/access step and the app list (SwiftUI)
  MenuTracker.swift           On-screen menus/popovers via CGWindowList
  Log.swift                   Console / unified log / ~/Library/Logs output
```
