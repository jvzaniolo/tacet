# Menu bar management on macOS 27: notes

Written 2026-10-16 on macOS 27.0.1 (26A434). Sources:

- What this Mac shows: processes, defaults domains, and AX output from MenuShelf.
- Thaw's open (GPL-3.0) source at tag `3.0.0-alpha.9`, cloned to `../thaw-src`
  (outside this folder). Thaw code is not copied into MenuShelf; only the
  mechanisms are described here, in my own words.

## 1. What changed in macOS 27

- A new agent, `/System/Library/CoreServices/MenuBarAgent.app`
  (`com.apple.MenuBarAgent`), draws the whole bar. Its Info.plist registers
  FrontBoard scene workspaces, including `com.apple.appkit.status-items`. An
  app's `NSStatusItem` is now a scene hosted by MenuBarAgent, not a window of
  its own.
- `CGWindowListCopyWindowInfo` shows only full-width bar windows (owners
  "Window Server" and "MenuBarAgent", layer 24, 1800×39 here). There are no
  per-item windows, so these old tricks are gone:
  - Hidden Bar's ~10 000 pt separator item. Thaw's own comment: "Divider reflow
    cannot hide items".
  - Moving item windows off-screen with `CGSMoveWindow`. Thaw notes that moving
    a hosting window "collapses the entire bar".
  - Bartender and Ice's per-window cmd-drags. Thaw still does process-targeted
    cmd-drags, but only to reorder items.
- **Accessibility still works for reading and pressing items.** Each app's
  `AXExtrasMenuBar` still lists its items (`AXMenuBarItem/AXMenuExtra` with
  `AXPress`). MenuBarAgent's own items, the Apple modules, appear under its
  extras bar as `AXGroup/AXHostingView` with no name and no AXPress at the top
  level; the name and the pressable element are one or two levels down. On this
  Mac MenuShelf found 6 apps with 12 items, with sensible x positions.
- An item's owner should come from `AXUIElementGetPid(child)`, not from the app
  whose extras bar listed it, since MenuBarAgent hosts items for other
  processes.

## 2. How macOS 27 can hide items, and what Thaw does

Hiding is **per app** (per bundle ID of the owning process), not per item.
Thaw's open source names three mechanisms. The important caveat is that **the
main ones live in a closed binary.**

### 2a. "Standard" / "Everything": a bar-wide visibility restriction (closed)

- Thaw holds a system "assertion" on MenuBarAgent. While it is held, macOS
  hides every status item whose owning bundle is not on an allow-list.
  Revealing relaxes the assertion, and MenuBarAgent re-composites in about
  400 ms.
- Side effects listed by Thaw while the assertion is held:
  - Live Activities and the camera/mic indicator disappear.
  - A Clock click or the Notification Center shortcut is swallowed.
  - Pinned Control Center modules leave the bar.
  - Items report "parked" AX frames (around y ≈ 1400, or x = -1).
- The implementation is in **PlatformRuntimeKit**, a prebuilt xcframework from
  `github.com/thaw-app/prk-bin`, v1.1.1. Thaw's GPL repo has only protocols,
  comments and UI strings for it. Its license (PlatformRuntimeKit License 1.0)
  **forbids reverse engineering it, or reusing anything learned from it outside
  Thaw, for one year after each release**. After that, each version becomes
  GPL. I did **not** download, inspect or use the binary. MenuShelf does not
  implement this mechanism.

### 2b. "Native": System Settings › Menu Bar › "Allow in the Menu Bar" (closed writer)

- This is the per-app switch in System Settings. It is stored in Control
  Center's group-container preferences, `group.com.apple.controlcenter.plist`,
  in `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/`.
- That folder is protected. `ls` and `defaults read` both fail here with
  "Operation not permitted" or "domain not found".
- Thaw asks the user to pick that one file in an `NSOpenPanel` (see §3 for the
  pattern) and keeps a security-scoped bookmark. It journals its changes so it
  can undo them at the next launch, and it has a `--recover-menu-bar-visibility`
  mode.
- The file's schema and the writer are in the closed kit. I could not read the
  file myself, and I won't guess at a schema and write to it blind.
  Not implemented.

### 2c. Per-item `VisibleCC` switch in the owning app's preferences (**MenuShelf uses this**)

- AppKit keeps `NSStatusItem VisibleCC <autosaveName>` (Bool) in the **owning
  app's** defaults domain. When it is false, the item is not published to the
  bar.
- On this Mac, System Settings has written such keys:
  - `com.raycast.macos`: `NSStatusItem VisibleCC calendar-events = 0`
  - `com.apple.controlcenter`: `NSStatusItem VisibleCC WiFi = 1` and others
- Thaw's open source has this as an **experimental, off-by-default** option
  ("Native Always-Hidden": "writes NSStatusItem VisibleCC <label> = false into
  the owning app's domain so the host stops publishing the item"). It also
  treats an item with VisibleCC = 0 as "hidden by System Settings".
- Thaw's comments also say a VisibleCC of 0 "prevents AppKit publication, which
  later appearance updates cannot repair". AppKit probably reads the key only
  when it creates the item, so **an app may need a relaunch** before a change
  shows. MenuShelf rescans 1.5 s after each change and logs whether the app's
  AX items changed, which shows whether this happens live.
- Autosave names come from three places:
  - The app's own keys: `NSStatusItem Visible|VisibleCC|Preferred Position <name>`.
  - MenuBarAgent's layout table keys `status:<bundleID>::<name>`.
  - AppKit's defaults for unnamed items, `Item-0`, `Item-1`, …
- Limits:
  - Non-sandboxed apps only. A sandboxed app reads its preferences from
    `~/Library/Containers/<id>`, which MenuShelf won't write. All of this Mac's
    menu bar apps are unsandboxed.
  - MenuShelf won't touch Apple items. System Settings › Control Center owns
    those switches.

## 3. "Menu Bar Layout Access": the menu bar order

- macOS 27 stores item order in MenuBarAgent's group container
  `~/Library/Group Containers/com.apple.MenuBar` (protected; `ls` fails here). It
  is a CFPreferences plist read through cfprefsd.
- Key `TrailingItemPreferredPositions`, a dictionary of sort weights. Key forms:
  - `status:<ownerBundleID or display name>::<autosaveName>`
  - `module:<Name>`, e.g. `module:WiFi`, `module:Clock`, `module:BentoBox-1`
- The host rewrites this table continuously, so Thaw re-reads it before every
  write. A write makes MenuBarAgent re-sort the bar in well under a second.
- A legacy copy at `~/Library/Preferences/com.apple.MenuBarAgent.plist` is still
  readable here. It has the same key, plus analytics keys, and
  `defaults read com.apple.MenuBarAgent` shows it. Thaw deletes it on "reset",
  so treat it as possibly stale. MenuShelf only reads it, to find autosave
  names.
- How Thaw gets access, with the file-picker pattern visible in its open
  `PickedFileAccess`:
  - `NSOpenPanel` with `canChooseFiles`, `allowedContentTypes = [.propertyList]`,
    and `directoryURL` set to the file's folder. The picked path must equal the
    expected path.
  - `bookmarkData(options: .withSecurityScope)` is stored in UserDefaults; at
    launch it is resolved and `startAccessingSecurityScopedResource()` is called.
  - The app is unsandboxed with the `com.apple.security.files.bookmarks.app-scope`
    entitlement.
  - If the user dismisses the panel, the fallback is Full Disk Access
    (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`).
  - Order is only needed for **reordering** (move items without cmd-drags). It is
    not needed for hiding, so MenuShelf does not ask for it yet.

## 4. The native overflow arrow

- When items don't fit, MenuBarAgent shows its own chevron. Thaw finds it with:
  1. the `AXOverflowButton` attribute on MenuBarAgent's extras bar;
  2. a child of that bar with role `AXButton` (real items are `AXGroup`);
  3. on notchless displays the indicator can be a composited `AXImage` outside
     the extras bar, so Thaw falls back to AX hit-testing across the bar strip
     (`AXUIElementCopyElementAtPosition`);
  4. as a backstop, labels: titles containing "chevron", the strings
     `menuBar.showOverflowItemsAccessibilityLabel` /
     `menuBar.hideOverflowItemsAccessibilityLabel` from MenuBarAgent's
     `MenuBarCore.loctable`, and "Show Hidden Menu Bar Items".
- MenuShelf implements 1 and 2 and shows the result in Settings and in the debug
  dump.

## 5. Opening items

`AXUIElementPerformAction(element, kAXPressAction)` on the item, or on the
first descendant that supports AXPress (needed for MenuBarAgent's groups).
Thaw also treats `.cannotComplete` as success when a menu opened. Its last
resort is a process-targeted click, which MenuShelf doesn't do.

## 6. Status in MenuShelf

| Feature | State |
| --- | --- |
| Enumerate items per app (AX) | Works. Verified on this Mac: 6 apps, 12 items. |
| Owner from `AXUIElementGetPid`, MenuBarAgent child names | Works. Verified: e.g. `com.apple.menuextra.wifi` "Wi‑Fi, conectado, 3 barras", `…clock`, `…now-playing`. |
| Overflow arrow (AX attribute + AXButton) | Works. Verified: present at x≈1047, 17.5×36 pt. |
| Hide/show per app (`VisibleCC`) | Built. Prefs write/restore covered by `--selftest` (passes) and seen live in the log. **Visual effect unverified**, see below. |
| Relaunch a changed app | Built, only on explicit click. |
| Restore everything on quit; reconcile at launch | Built. Quit-restore ran in the log. |
| Bar-wide restriction (Thaw "Standard") | **Blocked**: closed SPI, license forbids reverse engineering. |
| Control Center "Allow in Menu Bar" list (Thaw "Native") | Not built: needs the user to pick a protected file whose schema I couldn't see. |
| Reorder through layout table | Not built (out of scope). |

### First live run (2026-10-16, 03:00 UTC)

- 1Password, Claude and ChatGPT were marked Hidden. None had stored names, so
  `Item-0` was used for each. `VisibleCC Item-0 = 0` was written and restored
  correctly as the chevron was toggled.
- 1.5 s after each write, **each app still had its AX item**. So AppKit does not
  remove the item live, or at least not from AX.
- Their x positions did change: 1Password 1168 → 1031 → 737, ChatGPT
  1138 → 1033 → 707. The native overflow arrow was at x≈1047, so the
  "hidden" items now sit **left of the arrow**, which may mean inside the
  overflow area. A changing Raycast text item resized at the same time, so
  this may be ordinary crowding rather than an effect of `VisibleCC`.
- To settle it, someone has to look at the bar, or relaunch one Hidden app
  (Settings → Relaunch) and check whether its item comes back after the
  relaunch.
- Cosmetic: some MenuBarAgent items expose custom actions whose names span
  several lines ("Name:Remover da Barra de Menus\nTarget:…"), which makes the
  debug dump wrap.

## 7. Next steps worth trying

1. Grant Accessibility, mark an app Hidden, and read
   `~/Library/Logs/MenuShelf.log` for the `After apply:` line. If the app's AX
   item count drops, hiding is live; if not, use **Relaunch to Apply**.
2. Add an opt-in "Control Center app list" grant: pick
   `group.com.apple.controlcenter.plist` in a panel, then **read only** and dump
   its keys. Compare a System Settings › Menu Bar toggle before and after to
   learn the schema from macOS itself.
3. Hand MenuShelf a Developer ID or another stable signing identity, so
   rebuilds don't reset the Accessibility grant.
