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

---

## 8. Spike: reusing the native overflow arrow with a spacer (2026-10-16)

**Goal:** a "Hidden Bar on top of Apple's overflow". A wide NSStatusItem
("spacer") pushes the items to its left into macOS 27's native overflow, so
Apple's arrow, animation and real hiding do the work. The user sets hidden
vs. visible with native ⌘-drag.

**Setup:**
- One Mac: built-in 1800×1169 pt notch display (notch spans x 790–1010).
  No external display was tested.
- Tooling (kept in the repo, spike-only):
  - `Sources/MenuShelf/Spike.swift`: spacer, AX probe, arrow watcher.
  - `scripts/spike.swift`: sends commands, e.g. `build/spike spacer 300 divider`.
  - Run MenuShelf with `--spike`, which also turns the VisibleCC hider off.
- Raw evidence is in `~/Library/Logs/MenuShelf.log` (`SPIKE` lines).

### Verdict: **partially viable**

Hiding works and is native (truly hidden, Apple's arrow, no permissions
needed for the spacer itself). **Revealing does not feel native.** The
expanded overflow shows a gap as wide as the spacer, and shrinking the spacer
to remove the gap makes the icons jump back onto the main bar. The spacer's
width also has to stay inside a narrow band, or the hidden items become
unrecoverable or come back on their own.

### What was observed

**(a) Does the arrow appear?** Yes.
- This bar was already crowded, so the arrow existed before the test (x≈1053,
  right of the notch).
- With a 300 pt spacer ⌘-dragged to between Claude and Raycast's text item,
  the arrow moved to sit right next to the spacer (x 1276).
- Everything left of the spacer went into overflow: 1Password, Raycast,
  Now Playing, Stats, Claude.
- MenuBarAgent's drawn-bar list confirms those items are collapsed under the
  arrow, not drawn on the bar.

**(b) Which items overflow?** The leftmost ones, nearest the notch or the app
menus.
- macOS lays out right to left. The first item that doesn't fit, and
  everything left of it, go into overflow.
- A spacer wider than the space left over is that first item. So: everything
  left of the spacer is hidden, everything right of it stays visible.

**(d) Does the spacer itself overflow?** Yes, always: it is the item that
doesn't fit.

**Width is not "the bigger the better".** Hidden Bar's 10 000 pt trick does
not carry over.

| Spacer width | Result on this bar |
| --- | --- |
| 200 pt, left of everything | Spacer overflows alone; nothing changes |
| 300 pt, 600 pt | ✅ Works: spacer + everything left of it in overflow, arrow next to it |
| 800 pt (repeated twice) | ❌ No arrow at all; all app items gone, only Apple's 7 drawn. Nothing can be revealed |
| 1200 pt, 4000 pt | ❌ Spacer dropped from the bar; all items return |

- A product would need to compute the width live: just over the free space.
- On a notch display the free space runs from the spacer's right neighbour to
  `NSScreen.auxiliaryTopRightArea.minX`.
- The frontmost app's menus didn't matter here, because the notch is the
  boundary. Without a notch the boundary is the end of the app menus, so the
  width would change with every app switch. That causes relayouts, and it is
  untested.

**(c) Expanding with the spacer present.**
- Clicking the arrow lays the overflow out **left of the notch, over the app
  menus**. The user's photo shows ChatGPT, MenuShelf, 1Password, Raycast,
  Now Playing, Stats and Claude covering the "Arquivo…" menus.
- **The spacer comes along:** a 300 pt empty gap between the revealed icons
  and the notch, ending at the spacer's divider line.
- Some items didn't fit in the expanded area and stayed collapsed
  (OrbStack at 600 pt).
- **Shrink on expand** (300→8 pt when the arrow says "Hide…", back to 300 on
  "Show…"): the gap disappears, but the user saw icons "jump around before
  settling". The probes explain it:
  - Apple's expand animation runs first.
  - Then the shrunken spacer frees space, so the hidden items **reflow onto
    the main bar** right of the notch (x 1071–1332).
  - The overflow stays "expanded" with only the items that really don't fit.
  - On a bar that isn't crowded the arrow would probably disappear entirely
    at that point (not tested).

**(e) Width vs. frontmost app, notch, external display:** see above. The
built-in notch display works with a fixed boundary. Non-notch and external
displays were not tested.

**Initial placement:**
- A new spacer appears **leftmost** and immediately overflows, hiding nothing.
- Writing `NSStatusItem Preferred Position MenuShelfSpacer` in our own
  defaults did **not** move it on macOS 27. Order lives in MenuBarAgent's
  protected table (§3).
- **The user must ⌘-drag it into place once.** ⌘-drag worked on the first
  try, done while the overflow was open. During the drag the arrow vanished
  for about 0.4 s and came back.

### Open/close behaviour of the native overflow (to copy)

- Opens on click of the arrow. The label switches from "Show Hidden Menu Bar
  Items" to "Hide Menu Bar Items" (pt-BR here: "Mostrar Itens Ocultos…" /
  "Ocultar Itens…").
- **No auto-close timer.** It stayed open for 31 s, 42 s and 116 s untouched.
- Closes on a click outside, or on the arrow again. Quick re-clicks toggled
  it within 1–3 s.
- Each open/close creates and destroys an `AXWindow` in MenuBarAgent
  (`AXCreated` / `AXUIElementDestroyed`). There is no `AXExpanded` attribute
  and no actions on the arrow.
- Expanded icons are drawn left of the notch, over the frontmost app's menus.

### Icon

- MenuBarAgent's binary references `chevron.backward.2` and
  `chevron.forward.2`.
- The user's photo of the open overflow shows **»**, so it is
  `chevron.forward.2` when open and `chevron.backward.2` («) when closed.
  Thaw's notes call the notchless indicator "Double backward chevron".
- Use those SF Symbols for our own control.

### ⌘-held divider

- With the spacer in place, the boundary is effectively the native arrow: the
  spacer itself is hidden inside the overflow.
- A visible divider only appears while the overflow is open. The divider image
  (a 1 pt line at the spacer's right edge) is the thin line in the user's
  photo.
- Showing it only while ⌘ is held can be done without permissions by polling
  `NSEvent.modifierFlags` (a class property). A global `flagsChanged` monitor
  would need Accessibility or Input Monitoring.
- Whether a dragged icon dropped just left of the collapsed arrow goes into
  overflow was not tested.

### Permissions per piece (for the $5 / App Store question)

| Piece | Permission |
| --- | --- |
| Spacer status item, any width | None (plain `NSStatusItem`) |
| Native ⌘-drag to configure | None (macOS feature) |
| Notch boundary for width | None (`NSScreen.auxiliaryTopRightArea`) |
| Knowing whether the overflow is open | Accessibility (arrow label). **Probably none:** our own spacer's window frame jumps to the left area when expanded (logged `buttonWindow=(454…)` vs `(1277…)`), but this was not tested as a signal. |
| Right-neighbour position for an exact width | Accessibility, unless derived from our own spacer frame |
| Reordering items for the user | Protected layout table (file grant or Full Disk Access) or Accessibility + synthetic ⌘-drags. **Not needed** if the user ⌘-drags. |
| Item images | Screen Recording (not needed here) |

So a **sandboxed, permission-free** build looks possible for "spacer + native
arrow + ⌘-drag". It is not verified in a sandbox. The cost is the
reveal experience: a gap, or jumps.

### Recommendation

1. **Don't ship "pure native overflow + spacer" as the headline.** The reveal
   gap or jump breaks "feels native".
2. **Fallback (documented, not built):**
   - Keep the spacer for **hiding**: it's native, permission-free and uses
     ⌘-drag config. Size it live, inside the safe band.
   - Add **our own** always-present chevron (`chevron.backward.2` /
     `chevron.forward.2`) right of the spacer.
   - Clicking it reveals by shrinking the spacer, so items reflow inline the
     way Hidden Bar does. Add a spring (bounce) + fade overlay to mask
     MenuBarAgent's relayout.
   - Copy the native close rules: click outside or on the chevron, no timer.
   - Caveat: macOS's own arrow appears whenever the spacer causes overflow, so
     two chevrons sit side by side while collapsed. Test whether that is
     acceptable, or whether the spacer can be kept just under the overflow
     threshold.
   - The VisibleCC per-app hiding (§2c) is a possible complement for apps that
     shouldn't even live in the overflow. Its visual effect is still
     unverified.
3. Before deciding, test on a **non-notch external display** and on an
   **uncrowded bar**. The dead-zone widths and the reflow behaviour may differ.

---

## 9. Spike: native overflow with a minimal gap (2026-10-16)

**Question:** if the spacer is sized live to *just* overflow, is the gap in
the expanded overflow small enough to feel native?

**Tooling (spike only):** `Sources/MenuShelf/SpikeAuto.swift`.
- `build/spike sweep <from> <to> <step>`: resizes the spacer and logs AX
  geometry plus the spacer's own window frame at each step.
- `build/spike geo`: logs the gap while the overflow is expanded.
- `build/spike auto on`: an AX-based live sizer. It is a prototype: its
  "first visible item" lookup is only right while the spacer is overflowed,
  and it was **not exercised**. See "Not tested".

### Verdict: **not viable → go to option 3 (our own bar)**

The minimal gap is not small. It equals the empty stretch between the notch
(or the app menus) and the first visible icon, minus about 55 pt, and it
grows with every icon you hide. Worse, the spacer takes room in the
**capped expansion area** left of the notch, so with many hidden icons the
open overflow **doesn't draw some of the hidden icons at all**. "Native
animation + configurable" can't be had this way.

### Measurements (built-in 1800 pt notch display, notch 790–1010)

**Threshold.** The spacer grows **leftward from a fixed right edge**, and
overflows exactly when

```
W ≥ spacerRight − notchRight − 53 pt   (arrow already present)
```

| Layout | Spacer right edge | Predicted W* | Measured |
| --- | --- | --- | --- |
| Divider between Claude and Raycast "OCB" | 1342 | 279 | fits at 278, overflows at 280 |
| Divider just left of Wi-Fi (most icons hidden) | 1470 | 407 | fits at 400, overflows at 410 |

- The 53 pt is the space the arrow needs when it is already on the bar (on
  this crowded bar, other items overflow anyway).
- On a bar where nothing else overflows, the constant should be smaller,
  since the spacer would fit without the arrow. **Not measured.** A live
  sizer has to stay over the higher, no-arrow threshold to be safe, which
  adds roughly 30 pt more gap.

**Gap with the overflow open, spacer at the minimum width (not shrunk on expand):**

| Scenario | Spacer | What the user sees |
| --- | --- | --- |
| Native, no spacer (bar crowded on its own) | — | **65 pt** from the last revealed icon to the notch |
| Crowded bar, divider before "OCB" | 282 pt | **317 pt** gap to the notch. User: "gap still big"; animation itself native. Photo: revealed icons stop at Claude's ✳︎, then empty bar through the notch to the » arrow. |
| Most icons hidden, divider before Wi-Fi | 410 pt | Spacer fills x 351–763. **Only Claude and "OCB" are drawn**; OrbStack, ChatGPT, MenuShelf, 1Password, Raycast and Stats are absent from MenuBarAgent's drawn list, so they **can't be reached at all** |
| Few menu bar apps (true uncrowded) | — | **Not tested** (would require quitting your apps). Expected the same as the row above: the free space is larger, so the spacer is wider. |
| External / non-notch display | — | **Not tested.** No external display connected (`NSScreen.screens` has only the built-in one). |

**Why it can't get small:**
- The spacer has to be wider than the empty stretch it sits in. That stretch
  includes the room freed by every icon it hides.
- When the overflow opens, MenuBarAgent lays out the overflow group,
  *including the spacer at full width*, in the area left of the notch:
  roughly from the end of the app menus to x 790.
- That area is fixed. The spacer competes with the hidden icons for it, and
  icons that don't fit aren't drawn.
- That's also the §8 dead zone: at about 800 pt the spacer alone can't fit
  in it, so there's no arrow and nothing can be revealed.

### Live sizing: inputs found, not needed

The inputs for the sizer can be read without Accessibility, but given the
verdict a live sizer wasn't pursued further:

| Need | Permission-free source (verified) |
| --- | --- |
| Spacer's right edge | Spacer's own `button.window.frame.maxX` (−7 pt). It stays constant as the spacer grows, overflowed or not. |
| Did it overflow? | Own window `maxX` moves left by 8 pt at the threshold (1349 → 1341). Seen in the first layout only: the second sweep ran with the overflow open. |
| Is the overflow open? | Own window jumps into the left area (x 1043 → 472) |
| Notch boundary | `NSScreen.auxiliaryTopRightArea.minX` / `auxiliaryTopLeftArea.maxX` |
| Non-notch boundary (end of app menus) | No public permission-free source found. AX `kAXMenuBarAttribute` of the frontmost app works. |
| Triggers | Spacer window move/resize notifications, `NSWorkspace` launch/quit, `NSApplication.didChangeScreenParametersNotification`. Debounce ~0.5 s and use ≥3 pt hysteresis, because every resize relayouts the bar. |

### Edge cases

- **Width change while the overflow is open** (tested in §8 by shrinking):
  the bar relayouts, and freed icons fly back onto the main bar. Any live
  resize while open will jump, so a sizer must freeze while open.
- **Icon added or removed while open:** not tested (would need you to
  quit/launch an app). The same relayout is expected.
- **⌘-drag:** works for moving the divider. A resized spacer keeps its
  dragged position, even across `removeStatusItem` + re-create (same
  `autosaveName`).

### Permissions (for comparison with option 3)

- **This approach:** a sandboxed, permission-free build is plausible on notch
  displays (own window frame + `NSScreen`). Non-notch displays need
  Accessibility to find the end of the app menus.
- **Option 3 (our own bar / panel):** hiding still needs a hiding mechanism.
  - The spacer can still do the hiding, with no permissions.
  - Showing hidden items in our own panel means drawing their images (Screen
    Recording) and forwarding clicks (Accessibility: AXPress on the real item).
  - So option 3 likely needs Accessibility, plus optional Screen Recording
    for icons. That makes the Mac App Store unlikely; ship direct ($5 via
    Paddle/Gumroad, notarized).

### Recommendation

**Go to option 3:**
- Keep the spacer only as the *hiding* mechanism. It is permission-free and
  configured with ⌘-drag, as tested.
- Reveal in **our own** panel or bar under the menu bar, using our own spring
  (bounce) + fade animation and `chevron.backward.2` / `chevron.forward.2`,
  with Apple's close rules (click outside or on the chevron, no timer).
- Apple's arrow will still exist whenever the spacer causes overflow. Test
  whether it's acceptable to leave it, or whether to size the spacer so that
  it is the only thing overflowing.

---

## 10. v1 design: spacer hides, our panel reveals, one arrow (2026-10-16)

### Choosing the hiding mechanism

| Option | Evidence | Verdict |
| --- | --- | --- |
| Per-app `VisibleCC` (§2c) | `NSStatusItem VisibleCC MenuShelfChevron = false` on MenuShelf's own item. **Live: no effect** (still drawn). **After relaunch: really gone**, from both AX and MenuBarAgent's drawn list. The freed room also made Apple's arrow disappear. | True hiding, but **only when the app creates the item**, so every hide or show needs the app relaunched. An unpublished item can't be opened either. Unusable for click-to-reveal. |
| Spacer (§8–9) | Hides natively, no permission. Apple's arrow then always appears at the spacer's right end. | **Chosen** for hiding. |

**Getting exactly one arrow:**
- macOS's arrow *is* `chevron.backward.2`. So we don't add a second chevron:
  we keep Apple's arrow and lay an almost transparent, click-catching window
  over it (`ArrowCatcher`).
- Its clicks open *our* panel, so Apple's expansion (with its gap, §9) never
  runs.
- While our panel is open the catcher draws a pressed capsule with
  `chevron.forward.2`, like the native control does when expanded.
- Verified: with the panel closed, the bar has Apple's arrow and nothing else
  of ours. The spacer is inside the overflow.

### How v1 works (`Sources/MenuShelf/Shelf/`)

- **`HidingSpacer`**
  - Status item `MenuShelfSpacer`, sized live to
    `rightEdge − boundary − 53 + 8` pt with 3 pt hysteresis. `rightEdge` is
    corrected by +8 pt while overflowed.
  - Boundary: the notch's right edge, or the end of the app menus.
  - Refuses targets over 740 pt (§8 dead zones) instead of clamping, so a
    wide display never makes the width oscillate.
- **Edit mode** (first run, or right-click → Edit Layout…)
  - The spacer shrinks to a 22 pt visible divider; you ⌘-drag icons across it.
  - On Done, MenuShelf photographs the bar (all icons are visible then), saves
    the order, and re-hides.
- **`ArrowCatcher`**: left-click toggles the panel; right-click or ⌃-click
  opens our menu (Edit Layout, Refresh Item Images, Permissions, Diagnostics,
  Quit).
- **`RevealPanel`**: borderless non-activating `NSPanel` at status-bar level + 1.
  - **Inline** in the empty bar left of the arrow when it fits, with no
    background, so the icons look like they returned to the bar. On notch
    displays the room the hidden icons left is exactly that gap. Otherwise a
    dropdown in menu material under the bar.
  - Animation: `CASpringAnimation` on translation (14 pt from the arrow side,
    stiffness 340, damping 26, ≈ 0.35 s with a light overshoot) plus a
    0.18 s fade. Close: 0.16 s fade.
  - User: "open animation is awesome".
- **Images** (`ItemImageCache`)
  - One ScreenCaptureKit capture of the bar strip (Screen Recording), cropped
    per item, kept in memory and in `~/Library/Application Support/MenuShelf/ItemImages`.
  - Never captured on click. Without Screen Recording, app icons are used.
  - Items still in overflow at capture time are skipped (cropping there
    captured Apple's arrow).
  - The cache key ignores digits, because text items like "13m left" change.
- **Opening an item**: AXPress on the real (overflowed) item. The panel
  closes first, like the native overflow.
- **Closing**: global mouse-down outside the panel and catcher, or a click on
  the arrow. No timer.
- **Isolation**: the default launch is v1. `--legacy` runs the first
  prototype (VisibleCC + list window). `--spike` adds the spike controller.
  `--debug` lets the shelf accept commands from `scripts/spike.swift` (snap,
  open, close, press n, width w, auto, edit, done). Debug only, because any
  local process could send them.

### Verified on this Mac (built-in notch display, Dell unplugged)

- The spacer settled at 453 pt and hid 7 icons (OrbStack, ChatGPT,
  1Password, Raycast, Stats, Claude, Raycast "OCB"). Wi-Fi, A/V, Battery,
  Control Center and Clock stayed visible.
- Panel opened inline at x 1101–1484 with real images. Your photo shows the
  icons in bar order and our » capsule.
- **Open animation:** you confirmed it works and looks good.
- **Closing on an outside click:** you closed the panel this way during the
  test.
- **Opening items:** OrbStack and Stats → `AXPress` = 0 (success).
  - Stats' popover appeared at x 867–1147 under the bar. That is the item's
    parked overflow position (just right of the notch), about 200 pt left of
    its icon in our panel. Sensible, but not aligned.
  - `defaults write dev.menushelf.MenuShelf pressMode reveal` switches to the
    alternative: let items back onto the bar, then press, so the menu lands
    under the real icon. Built, **not tested**, and it relayouts the bar.
- **Permissions:** Accessibility + Screen Recording both granted; with the
  "MenuShel Dev" self-signed certificate they survived rebuilds.

### Not working / not verified

- **Wide external displays without a notch:** the spacer can't hide there.
  - On the Dell (2560 pt, app menus ending at x 73) hiding needed about
    1724 pt. From 1000 pt up macOS drops the spacer.
  - v1 keeps the width it computed for the notch display, so the Dell simply
    shows everything.
  - With both displays connected, AX keeps reporting the Dell's bar even with
    focus on the MacBook. The width then only updates when the MacBook bar
    is the one reported.
  - Multi-display needs real work before v1 ships.
- Exact native close behaviour when an item's menu opens: we close our
  panel; native behaviour not compared.
- Hover states, keyboard (Esc), VoiceOver for the panel, dark/light
  appearance of the » capsule (only seen in one appearance), Stage Manager
  and full-screen spaces.
- An app adding or removing an icon while the panel is open (a refresh
  happens within 2 s; not exercised).

### Permissions summary

| Piece | Permission |
| --- | --- |
| Hiding (spacer), ⌘-drag config | None |
| Finding hidden items, arrow position, opening items | **Accessibility (required)** |
| Real icon images | Screen Recording (optional; app-icon fallback) |
| Menu bar layout file | Not used |

Accessibility is required, so **not Mac App Store**. Ship as a notarized
direct download.

### Left for v1

- Multi-display (see above). Ideally detect the menu bar each display shows
  and accept that wide displays show everything.
- Real Developer ID signing + notarization (hardened runtime: AX and SCK work
  with it; test). Sparkle for updates.
- Licensing for $5 lifetime: Paddle/Lemon Squeezy/Gumroad license keys with
  offline check.
- Launch at login (`SMAppService.mainApp`), an app icon, a settings minimum
  (show hidden on hover? hotkey?).
- Remove or rewrite the legacy and spike code before release. It is behind
  flags now, but still compiled in. The VisibleCC code writes other apps'
  preferences.
- No Thaw/Ice code is used anywhere. All implementation is original; Thaw
  was only read for mechanisms.

---

## 11. MenuShelf on MenuBarAgent's restriction (2026-10-16)

The user chose to make MenuShelf as native as possible:
- hide and show with MenuBarAgent's own visibility restriction;
- let macOS animate the real icons;
- **no spacer fallback**.

This supersedes §10. The panel, cover, arrow catcher, image cache, spacer,
Screen Recording request, VisibleCC code and spike tooling are all removed
(git history keeps them). Background research is in `../research/REPORT.md`
§3c–§5.

### Provenance and licence

- The shim (`Sources/MenuShelf/MenuBarAssertion.swift`) was written from
  **class and selector names only**:
  - Listed from the framework's own Objective-C runtime on this Mac:
    `dlopen` of `/System/Library/PrivateFrameworks/MenuBarClientCore.framework`,
    then `class_copyMethodList`.
  - Cross-checked against public prose: Sowyu's comment in
    [Thaw discussion #737](https://github.com/thaw-app/Thaw/discussions/737),
    the Apache-2.0 BarNook/Ellipsis `docs/phase0.md` and `docs/spec.md`
    (docs only), and the public `AEMenuBarItem.h` header in the macOS 27 SDK.
- Thaw's PlatformRuntimeKit (binary or anything derived from it) was never
  downloaded, opened or used.
- No GPL code (Thaw, Ice) and no other project's code was copied.
- What the runtime shows on 27.0.1 (26A434):

```
MBAssessmentModeConfiguration  -initWithAllowedSystemItems:allowedBundleIdentifiers:  (NSArray, NSArray)
                               -allowedSystemItems / -allowedBundleIdentifiers
MBAssessmentModeAssertion      -init
                               -activateWithConfiguration:completionHandler:
                               -activateWithCompletionHandler:  -activate:completion:
                               -invalidate
```

- `allowedSystemItems` takes NSNumber codes. 0–6 follow the public
  `AEMenuBarItem` constants in header order: Battery, Bluetooth, Clock,
  Displays, Keyboard, Volume, Wi-Fi. 8 is Control Center (BarNook docs).
  MenuShelf allows 0–40.
- **Completion block, observed:** called within 1–26 ms with raw arguments
  `(0, 3)` on success. The first argument is the NSError pointer (0 = nil);
  the second is leftover register content. The shim takes raw values and
  never dereferences them, so a wrong signature can't crash.
- Not legal advice. Private API: if Apple changes it, MenuShelf stops hiding,
  and we fix it then. There is deliberately no fallback.

### Experiments (built-in notch display and the Dell U2724DE)

| # | Question | Result |
| --- | --- | --- |
| **E7** | Does our own chevron survive the allow-list? | **(b)** "MenuShel Dev"-signed in /Applications: **yes**. **(a)** ad-hoc signed in /Applications: **yes** (confirmed by the user). **(c)** signed but run from the build folder: **no**, our « is hidden although our bundle ID is allowed. → **Location matters, signing doesn't.** `build-app.sh` installs to /Applications. |
| **E1** | The native animation | **Conceal:** pixels change from ~180 ms to ~760 ms after the call (≈ 0.58 s), then a small settle at ~1 s (Now Playing leaving). **Reveal:** starts ~130 ms after the call, runs ≈ 0.48 s (443 → 921 ms); the hidden icons fade in while our chevron makes room. Activation completes in 1–26 ms; the rest is MenuBarAgent animating. The user sees it as fades ("no sliding"); it "feels native". |
| **E2** | Swap without a flash | hide{OrbStack, ChatGPT} → hide{OrbStack}. **Activate-then-invalidate:** only ChatGPT's spot changes. **Invalidate-then-activate:** wider change, then a second burst at ~1.27 s as OrbStack reappears and hides again (a flash). MenuShelf always activates first. |
| **E3** | Menu alignment after reveal | OrbStack menu at x 1208 for its icon at 1220. 1Password popover at 1284 for its icon at 1288. A MenuBarAgent item opened its own panel normally. **Aligned:** these are the real items in their real slots (v1 was ~200 pt off). |
| **E6** | Granularity, edge cases | Hiding Raycast removes both its items (icon + "Daily" text): per app. The freed space closes up with no native overflow arrow. **Works on the Dell (no notch)**: E1 and E7 were recorded on its bar. Not run: launching a new app or relaunching a hidden app while concealed. The allow-list follows `runningApplications` via KVO, but it's untested. |
| **E4** | Side effects while something is hidden | User's check. **Works:** Control Center. **Broken:** clicking the clock (no Notification Center); the green camera/mic indicator is missing; the Focus icon and Now Playing ▶ are hidden (▶ also seen disappearing in E1/E6). **No workarounds implemented**: the user decides (options below). |

### How MenuShelf works now

- **`Restriction`**
  - Holds one assertion and swaps it activate-first.
  - Retries after 250 ms, 1 s and 4 s on failure.
  - Re-applies when `NSWorkspace.runningApplications` changes (KVO; launch
    notifications miss `LSUIElement` apps).
  - Changes within 0.35 s of the last one are merged into one final state,
    and nothing is sent if it equals what's already held. Rapid on/off clicks
    used to stall the bar while MenuBarAgent finished each animation.
- **Our items**
  - Chevron: `chevron.backward.2` when concealed, `chevron.forward.2` when
    open, template image, no pressed capsule (`highlightsBy = []`).
  - Divider (a 2 pt line): only while editing.
  - They change in the same run-loop turn as the assertion request.
- **Edit mode** (first run, or right-click « → Edit Layout…)
  - No assertion; divider shown. ⌘-drag icons across it.
  - Done = click the divider or ». Accessibility reads the items once.
  - **Rule:** an app is hidden only when *all* its items' centres are left of
    the divider. An app with items on both sides stays visible: we never hide
    an icon the user put on the visible side.
  - Item centres are used because some AX frames are much wider than the icon
    (Claude's is 42 pt) and their right edge overlaps the divider.
- **Revealed:** an allow-everything assertion. The real icons are on the bar,
  so clicking between items, menus and popovers is fully native.
- **Close rules** (as the native overflow):
  - a click outside the menu bar and outside any menu (layer ≥ pop-up menu)
    or any new window of a hidden app;
  - Esc with no such menu open;
  - a click on ».
  - No timer. Clicks on the bar itself keep it open.
- **Permissions:** Accessibility only, and only to read the layout on Done.
  Hiding needs none. No Screen Recording.
- **Quit:** invalidating our assertions shows everything again.

### Side-effect options for the user (not implemented)

1. **Accept them.** Document that NC/camera/Focus/Now Playing are unavailable
   while hidden.
2. **Clock relay** (BarNook's approach):
   - on mouse-down over the clock, lift the restriction, replay the click
     ~10–80 ms later, then re-apply;
   - NC opens in ~0.4–0.7 s instead of ~0.17 s;
   - needs Accessibility and a global mouse monitor;
   - hidden icons flash unless masked.
3. **Replacement items** (Pelmet, justhide): MenuShelf shows its own camera
   indicator, Focus and Now Playing items while concealed.
4. **Auto-reveal** when the camera/mic turns on or media starts playing.

### Still open

- E6: an app launched or relaunched while concealed (KVO path untested).
- Multi-display with both bars live: hiding is per app, so it applies to
  every display. It's untested with the Dell and MacBook bars side by side.
- Opening a hidden item while concealed (search/hotkey): AXPress the parked
  element first, then reveal-that-app; not built.
- Release work: Developer ID signing + notarization (install to
  /Applications), Sparkle, $5 licensing, launch at login, an app icon.
