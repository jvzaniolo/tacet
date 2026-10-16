# Two arrows: MenuShelf and macOS 27's native overflow

Research for MenuShelf, 2026-10-16, macOS 27.0.1. This was read-only: no
status items were created and nothing on the menu bar was changed. Code from
other projects is described in my own words, not copied. Line numbers refer to
the clones in `research/repos/`.

Starting point: NOTES §13, "Open: the native overflow arrow", and the user's
screenshot. In it, Apple's overflow is expanded left of the notch (ChatGPT,
OrbStack). Right of the notch come Apple's », 1Password, Claude, **our »**,
then the visible items.

## TL;DR

- **Nobody has solved this cleanly.**
  - Thaw 3 never operates Apple's arrow. When items don't fit it switches to
    its own image panel (Thaw Bar), or optionally moves the extras into Hidden.
  - Pelmet clicks Apple's arrow only during an explicit Apply. Its own arrow
    still ends up behind Apple's « on full bars (issue #81, open).
  - Hidden Bar, MenuBarHider, OnlySwitch and Sapphire ignore the native
    overflow. Sapphire and Ellipsis/BarNook show their own panel instead.
  - Bartender's macOS 27 betas say "the native overflow can still flicker",
    and recommend "Move items that don't fit into Hidden".
- **Seeing Apple's arrow takes Accessibility, everywhere.**
  - Thaw: on 27 "AX is all that is left".
  - Pelmet finds the arrow by AX hit-testing about 185 points along the bar.
  - Opening the arrow programmatically is worse. AXPress is refused (Pelmet,
    Ellipsis). Only a real HID click with a hidden, warped cursor works
    (Pelmet), which also needs Accessibility.
- **The one permission-free signal is our own status item.**
  - MenuBarAgent collapses the **leftmost** items first: Ellipsis and BarNook
    measured this, and Pelmet #81 shows it happening to Pelmet's arrow.
  - NOTES §9 showed that our own item's window frame moves when that item
    collapses, and jumps left of the notch when the native overflow expands.
- **Recommendation: option (d), "be the first thing macOS tucks away".**
  - Keep our arrow as the **leftmost** trailing item, left of every hidden
    app.
  - On a reveal that doesn't fit, macOS itself collapses our arrow first
    (plus whatever else doesn't fit) behind its own «, drawn where the
    visible items start. So exactly **one arrow** shows at every moment.
  - The extra icons are reached through Apple's own expansion left of the
    notch, which is what the user asked for.
  - It needs no permission, no clicks on Apple's arrow and no images.
  - A global mouse monitor (no permission for mouse events) closes the cycle:
    the click that collapses Apple's expansion also re-hides MenuShelf's apps.
  - Experiments X1–X5 verify each step.
  - Optional later: (f) "make room while revealed" and (a) "reveal only what
    fits".

## 1. What macOS 27 does when the bar is full (evidence)

- **Fill and collapse.** MenuBarAgent fills the status region from the right
  and collapses the **leftmost** items that don't fit. It draws its « "where
  the drawn items start" (Ellipsis `docs/phase8.md:7-13`; BarNook
  `docs/phase8.md` is the same; measured in a VM with a short region).
  - "The Ellipsis icon is the first item to collapse when the set shows,
    because it is the leftmost."
  - With no room at all, only «, Control Center and the clock are drawn.
- **Collapsed items stay in the layout.**
  - Their AX frames stack at the region's left edge, or overlap the « by
    5–6 pt (Pelmet `PlacementGeometry.swift:33-57`; Thaw
    `MenuBarItem+Ordering.swift:31-36`).
  - Their width collapses to about 2 pt, or they park at x = -1. An app
    switched off in System Settings also parks at x = -1 (Thaw
    `OverflowDeficits.swift:84-116`).
  - A collapsed item still takes a click at its phantom frame, with nothing
    drawn there (Ellipsis phase 8).
- **Width causes the overflow, not hiding.** Revealing several items at once on
  a notch display brings up the « (Thaw `RevealCaptureRules.swift:45-55`).
  That's why Thaw captures one item at a time on notch displays.
- **No setting turns it off** (NOTES §13). Thaw's
  `enableExperimentalOverflowPrevention` only gives hidden items extreme
  layout weights so that they collapse first (`AdvancedSettings.swift:294-295`;
  the code is in its closed kit).
- **The arrow has no usable AX action.**
  - AXPress, a synthetic click, hover and long press didn't open it in
    Ellipsis' VM.
  - Pelmet opens it only with an HID-level CGEvent click at the arrow's centre,
    while hiding the cursor and warping it back
    (`PelmetEngine/ItemMover.swift:103-133`). It retries twice with a 700 ms
    settle (`OverflowToggle.swift:154-191`).
- **Finding the arrow needs AX.**
  - Thaw's options: the `AXOverflowButton` attribute; a bare `AXButton` child
    of MenuBarAgent's extras bar; MenuBarAgent's localized labels from
    `MenuBarCore.loctable`; and, on notchless displays where the arrow is a
    composited image, an AX hit-test sweep of about 128 points
    (`MenuBarItemAXProvider.swift:814-1085`).
  - Pelmet's: about 185 hit-tests per pass, matched on label
    (`OverflowToggle.swift:69-99`).
  - Without AX: the window list on 27 holds only the backdrop, and
    MenuBarAgent's XPC needs private entitlements (Thaw
    `MenuBarItemAXProvider.swift:18-21`).
- **Our own item is the exception.** Its window frame is ours to read without
  any permission.
  - NOTES §9 measured on this Mac:
    - when the spacer itself overflowed, its window's maxX moved by 8 pt
      (1349 → 1341);
    - when the native overflow expanded, it jumped into the left area
      (x 1043 → 472).
  - kururu checks only its own item's window frame against the menu-bar band
    to notice it was dropped from a crowded or notched bar
    (`StatusItemAnchorSupport.swift:56-64`).
  - Thaw notes that the window is a zero-height stub
    (`OverflowSpacer.swift:27-28`). So use **x** only, not height. X1
    confirms this.
- **New items land far left.**
  - A status item registered under a never-seen `autosaveName` lands at the
    far left of the trailing items. That was verified for MenuShelf's spacer
    (NOTES §8), and justhide relies on it (`SpacerPlacement.swift:18-21`).
  - kururu calls the left end, next to the notch, "the first zone macOS drops
    from a crowded bar" (`MenuBarSpacingSupport.swift:312-317`).

## 2. How each app handles it

| App | Detects Apple's « | Operates it | When the revealed set doesn't fit | Own arrow vs. Apple's |
| --- | --- | --- | --- | --- |
| **Thaw 3** (`feat/thaw-3-alpha-10`) | Yes, AX only: attribute + role + labels + hit-test sweep (`MenuBarItemAXProvider.swift:997-1085`), with a tri-state that never treats "unknown" as "absent" | **Never.** The « is chrome: excluded from items and moves (`+Cache.swift:681-685`). Clicks on it are no longer "empty bar space" (CHANGELOG #1195; an earlier build broke Apple's « on notch Macs). | **Thaw Bar** (its own panel of captured icons) when the native overflow is active, or when a capacity check says the items "do not fit inline" (`MenuBarManager.swift:249-258`, `MenuBarSection.swift:84-129, 271-289`). Lanes: app-menu end → notch − 24 and notch + 24 → Control Center, minus the «. Optional **"Move items that don't fit into Hidden"** (off by default since beta.2, #1223): a budget per display that conceals the leftmost Visible items, never saved to the layout (`+LayoutReset.swift:100-383`; the #790 bug was ejections that were saved). | No special handling. Two arrows can show. |
| **Pelmet / Pliss** (0.3.x) | Yes, AX hit-test + labels. "Trapped" items = frames overlapping by more than 4 pt, two reads in a row (`AppState.swift:2428-2453`). | Only on **Apply** or a press of a trapped item: HID click with a hidden cursor, then closes it again. An earlier version that clicked on its own (`OverflowChevron.swift`) was deleted. | Leaves them behind «. The editor says "Your menu bar is full: N icons sit behind macOS's «". 0.3.2-beta.3+: a **Panel** mode with a "Didn't fit" section. | **Issue #81 (open):** on a MacBook Air, "macOS sent Pelmet's arrow behind its « with the rest"; the user thought "the Apple chevron covers the pelmet one". The maintainer: keeping it out "is still on my list". |
| **Ellipsis / BarNook** (Apache-2.0) | Via AX layout: a collapsed item lies left of « or overlaps another (`phase8.md`) | No (AXPress and synthetic clicks don't open it) | Default on notch Macs: a **floating bar** of app icons; the restriction stays (`spec.md:132-141`). BarNook pins: "hide as few apps as make room" from AX slot widths, in rounds, per screen (PR #17). Without AX, every other app is hidden. | Their icon is the leftmost, so it "collapses first". Accepted. |
| **Hidden Bar 1.11** | No. "Notch Overflow" (#420) just splits AX items at `auxiliaryTopRightArea.minX` | No | An `NSMenu` listing "Hidden Behind Notch" items, opened by AXPress (`NotchOverflowController.swift:37-278`). A spillover bar is planned (#366). | Not handled |
| **Sapphire** (AGPL) | Indirectly: drops items covered by a wider item (`MenuBarAgentHost.swift:35-63`) | No | Its own hidden-items panel for every item not drawn (`MenuBarHiddenItemsBar.swift:67-123`). It also activates itself to remove the frontmost app's menus when revealed items crowd them (`StatusBarController.swift:860-893`). | Recovers its control item if parked under the notch |
| **justhide** | No | No | A right-click menu of the hidden icons; each row opens its icon "where it would have been" by AXPress, **even while the app is switched off in System Settings** (measured 2026-10-13) (`HiddenIconsMenu.swift:7-16`) | — |
| **MenuBarHider, OnlySwitch, kururu** | No | No | Nothing | MenuBarHider uses a «/» glyph like Apple's, so the two are easily confused |
| **Bartender (closed), Golden Gate betas** | — | — | "Move items that don't fit on-screen into Hidden is the best way to smooth this over". Beta Three adds hiding *shown* items while revealing ("This gives the hidden items more room, then restores your usual bar"). | "The native overflow can still flicker briefly during some rearrangements" ([release notes](https://www.macbartender.com/goldengate/releases/)) |

Related reports:
- Thaw #924: hidden icons don't appear left of the notch.
- Thaw #1115: "Only Thaw bar will show hidden icons" on full notch bars in
  beta.1.
- Thaw #814 → "Swap" (exchange the Visible and Hidden sets).
- Pelmet #42: fighting macOS's reshuffle of overflowed icons; fixed by not
  correcting while the « exists.

## 3. The candidate solutions

### (a) Reveal only what fits

- **How others do it.**
  - Thaw computes lane capacity from AX widths, then chooses inline or its
    panel.
  - BarNook picks the fewest apps whose AX slot widths cover the shortfall,
    then re-reads and adds one more in each round until nothing is collapsed.
- **What MenuShelf has.** `trackedApplications` has no geometry:
  `menuItemLocations` only lists helper bundle IDs (justhide
  `MenuBarSwitches.swift:170-172`). So widths need AX, or must be learned
  (see d).
- **What to do with the leftovers:**
  1. Leave them hidden, but list them in our right-click menu and open one by
     AXPress, which works while it's switched off (justhide). Needs AX.
  2. A second click on our arrow reveals "the next page". Not native, and
     confusing.
  3. Our own panel: images, which the user already rejected.
- **Pros:** one arrow, nothing over the app menus.
- **Cons:**
  - The user doesn't get all hidden icons on the bar.
  - It needs widths (AX).
  - Text items such as Raycast's "Daily · in 7m" change width.
  - Results depend on the display.
- **Verdict:** good as an *option* later. Not the primary path while MenuShelf
  is permission-free.

### (b) Prevent overflow at rest (Bartender / Thaw "Move items that don't fit into Hidden")

- **How others do it.**
  - Thaw: a width budget right of the notch. When it is exceeded, conceal the
    leftmost Visible items (new ones first), using concealment only, never
    saved.
  - Bartender ships the same idea and still warns about flicker.
- **It doesn't fix this problem.** The two arrows appear on **reveal**, not at
  rest. At rest MenuShelf's hidden set is already off.
- **It costs:**
  - widths (AX);
  - automatic hiding of things the user put in Visible, which Thaw made opt-in
    after #1223 and which caused the persisted-ejection bug #790;
  - on non-notch displays, churn on every app switch, since app-menu width
    changes the budget.
- **Verdict:** no. At most, warn in Settings when the visible set alone doesn't
  fit (detected with X1).

**(b′) Make room while revealed** (Bartender Beta Three, Thaw "Swap"):
- While revealed, also switch off some Visible apps, in the same single write.
- The list is chosen by the user ("when revealing, also tuck away: …"), or
  automatic once X1 can detect overflow.
- **No permission needed:** MenuShelf already writes the switches and keeps a
  journal.
- **Cons:** visible icons vanish during a reveal, which isn't native, and
  more switches are flipped.
- **Verdict:** a reasonable optional setting, but not the default.

### (c) Merge the arrows by operating the system

- **Hide ours when Apple's appears.**
  - It needs to know that Apple's appeared: AX (§1).
  - Hiding our item is risky:
    - `isVisible = false` deletes its stored position (Ice
      `ControlItem.swift:544-562`), so it comes back at the far left;
    - length 0 needs AppKit constraint tricks (Ice `:106-123`, a FIXME);
    - even a 1 pt item reserves a slot (PWB97 Ice fork).
  - Freeing our slot can make everything fit again, so the arrows oscillate
    unless held until the conceal.
- **Make our click open Apple's expansion.**
  - Only Pelmet's HID click works: find the arrow by AX, hide the cursor,
    click, warp back, verify after 700 ms. AXPress fails.
  - That needs Accessibility. It moves the user's pointer while they're using
    it. Thaw deliberately never does this; Pelmet does it only on explicit
    Apply.
  - Pelmet's earlier automatic «-clicker was removed.
- **Verdict:** no. It brings Accessibility back for a fragile, pointer-moving
  trick.

### (d) Place our arrow so macOS tucks it away with the overflow (recommended)

**Mechanism.** Make MenuShelf's arrow the **leftmost** trailing item, left of
every hidden app:

```
rest:        [notch] … «ours  [visible …]  Clock
revealed,    [notch] … »ours  [hidden apps]  [visible …]  Clock
  fits:
revealed,    [notch] … «Apple  [the hidden apps that fit]  [visible …]
  overflow:     (ours + the leftmost apps are collapsed behind Apple's «)
Apple's «    left of notch: »ours  ChatGPT  OrbStack │ right: »Apple  1Password …
  clicked:
```

How it plays out:
- MenuBarAgent collapses leftmost first, so whenever the revealed set doesn't
  fit, **our arrow is the first casualty**. Apple's « is drawn where the drawn
  items start, roughly where ours was, and with the same glyph
  (`chevron.backward.2`). Exactly one arrow shows.
- Clicking Apple's « gives the **native expansion** left of the notch, with
  the rest of the hidden icons (and our », leftmost). These are real icons in
  macOS's own layout, which is exactly "the extra icons go left of the notch".
- **Closing:**
  - A click outside conceals as today. MenuShelf's switches go off, everything
    fits, Apple's arrow disappears and our « comes back.
  - Clicking our » inside the expansion conceals too.
  - For a native-feeling cycle, MenuShelf's existing global mouse-down monitor
    can treat **a click on Apple's » at the spot where Apple's arrow sits,
    while its expansion is open,** as "close" as well. The monitor observes
    and never swallows the click. Mouse monitors need no permission; only key
    monitors do.
  - Result: « (ours) reveals, « (Apple's) shows the rest, » (Apple's) puts it
    all away.

**Placement.**
- A status item registered under a **new** `autosaveName` lands at the far
  left (NOTES §8). MenuShelf can therefore anchor itself leftmost at first run,
  and re-anchor (a fresh name) if X1 shows something sitting left of it.
- The open question is whether a hidden app, switched back on, returns *right*
  of an arrow that was placed while the app was off. Pelmet says registration
  places from MenuBarAgent's in-RAM memory, and the plist is only read at an
  agent restart. X2 checks this.

**Permission-free signals.**
- Our own button's window frame (x only):
  - "drawn" = inside the bar, right of the notch;
  - "collapsed" = stacked or shifted, or parked off the row;
  - "expanded" = jumped left of the notch (NOTES §9).
- With our arrow leftmost and the bar right-anchored, the shift of our x on
  reveal = **the total width of the revealed apps**. MenuShelf can learn
  widths from this for (a) or (b′) later, without AX.

**Pros:**
- One arrow always, by construction, because macOS does it.
- Native expansion and animation.
- No Accessibility, no images, no pointer moves.
- Nothing extra drawn over the bar.

**Cons and risks:**
- Pelmet #81 shows users can be confused when the manager's arrow
  "disappears". MenuShelf differs in that it only happens while revealed, and
  only when the reveal truly doesn't fit. Onboarding or a one-time tip can
  explain it: "When there isn't room, macOS shows the rest under its own «".
- **At rest,** if the *visible* set alone doesn't fit, our arrow is collapsed
  and only reachable through Apple's expansion. Detect it (X1) and warn in
  Settings ("hide more apps").
- **A new app installed later** lands left of our arrow. If only it overflows,
  Apple's « sits right next to ours («« visible). Re-anchor (fresh name) when
  X1/X2 show we're no longer leftmost.
- The "click on Apple's » closes all" rule depends on knowing where Apple's
  arrow is. Use our last drawn x as the zone, and measure the offset (X3).
- Non-notch displays: the region's left edge is the app menus. A wide app
  menu (Chrome) can make the overflow come and go while revealed as the user
  switches apps, so our arrow flips between drawn and collapsed. Measure (X5).

### (e) Detecting Apple's arrow without Accessibility

**Direct detection of Apple's arrow: not possible without Accessibility.**
- Every working implementation reads it through AX: the attribute, the role,
  label text or a hit-test.
- On 27, `CGWindowListCopyWindowInfo` exposes only the full-width backdrop
  windows (Thaw; NOTES §1).
- `SLSGetRevealedMenuBarBounds` is for auto-hide and full-screen reveal, not
  overflow (Thaw `Bridging.swift:355-416`).
- MenuBarAgent's utilities service needs `com.apple.private.menubar.utilities`
  (BarNook `spec.md:59`).

**Indirect detection, without a permission:**
1. **Our own item's frame.** With (d), our arrow collapses exactly when there
   is overflow, so this signal is sufficient. This is the key experiment (X1).
2. **A sentinel.** If our arrow must stay right of the hidden apps, a second,
   invisible MenuShelf item kept leftmost does the same job. The cost is one
   reserved slot (≥1 pt; AppKit won't create a window for an item made too
   narrow, so it starts at a seed width and is shrunk once placed, per
   justhide).
3. **Arithmetic** (approximate): room = our arrow's minX −
   `NSScreen.auxiliaryTopRightArea.minX` − about 33 pt for Apple's «. That's
   Thaw's chevron footprint; NOTES §9 measured 53 pt with padding. Compare
   this with learned widths from (d).

**Saying it plainly:** if MenuShelf ever needs to know where Apple's arrow is,
or to click it, **Accessibility comes back.**

## 4. Recommendation

1. **Build (d).**
   - Our arrow is the leftmost trailing item. On launch, verify with X1/X2 and
     re-anchor with a fresh `autosaveName` if needed.
   - Let macOS tuck it away behind its own « when a reveal doesn't fit.
   - Add one rule to the close logic: a click in Apple's arrow zone while the
     expansion is open also conceals. The zone is known from our last drawn
     frame; the expansion state comes from X1's signal or a timing heuristic.
2. **Use our own frame as the only overflow signal.**
   - Log it (drawn / collapsed / expanded) in `MenuShelf.log`.
   - Show a Settings hint when even the rest state overflows.
3. **Defer (a) and (b′)** to options, built on widths learned from our
   arrow's shift. (a) with AX-based leftovers only if Accessibility returns
   for another reason.
4. **Don't do (b) or (c).** They need AX, move the pointer or hide visible
   items automatically, which caused bugs in Thaw (#790, #1223) and
   Bartender ("flicker").

## 5. Experiments for the build session

All of these change the menu bar, so run them in the build session. Use the
built-in notch display with Chrome frontmost, and the hidden set from the
screenshot (ChatGPT, OrbStack, 1Password, Claude, CleanShot). Record with the
60 fps ScreenCaptureKit stream (start ~1.5 s after the stream's indicator
appears), and log our button's `window.frame` every 50 ms.

**X1. Our frame as a signal.**
- Steps: with our arrow in its current place (right of the hidden apps),
  reveal and log our frame. Then ⌘-drag our arrow to the far left, or
  re-register it under a new `autosaveName`, and repeat. Then click Apple's «
  and Apple's ».
- Measure:
  - our frame's x and y, and whether the frame is on screen, in each state:
    rest, revealed-fits, revealed-collapsed, native-expanded;
  - whether "collapsed" is distinguishable: stacked x, an 8 pt shift as in
    NOTES §9, an off-row parking, or nothing;
  - the time from the write to a stable frame.
- Pass: three states are distinguishable from our own frame.

**X2. Leftmost placement holds.**
- Steps:
  1. With the hidden apps off, register our arrow under a fresh name and
     check it lands leftmost.
  2. Reveal, and check whether each hidden app returns **right** of our arrow.
  3. Relaunch MenuShelf; quit and relaunch a hidden app; install or launch a
     new menu bar app.
- Measure: the order after each step, via a screenshot.

**X3. The one-arrow cycle.**
- Steps: rest → click our « → (overflow) → click Apple's « → click Apple's ».
- Measure:
  - whether only one arrow is visible in every frame (including during the
    ~0.5 s animations);
  - where Apple's « lands relative to our last x;
  - whether our » appears inside the expansion and conceals when clicked;
  - whether a prototype rule (a mouse-down within ±20 pt of our last x while
    expanded → conceal) closes everything on the third click without breaking
    Apple's own toggle.

**X4. Mouse monitor without permission.**
- Steps: confirm that `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)`
  fires for clicks on Apple's arrow and on the expanded items, with
  Accessibility off for MenuShelf.

**X5. Display and app-switch churn.**
- Steps: while revealed, switch between Finder (short menus) and Chrome (long
  menus) on the Dell. Also try a bar where nothing overflows.
- Measure: whether our arrow flips between drawn and collapsed on every
  switch, flicker, and how long until things settle.

**X6 (optional). Make room while revealed (b′).**
- Steps: one batched write that turns the hidden apps on and two chosen
  visible apps off.
- Measure: the animation (one pass?), whether everything fits inline, and the
  journal/restore path.

**X7 (optional, only with AX). Reveal only what fits (a).**
- Steps: compute the shortfall from slot widths as BarNook does, reveal that
  subset, and list the rest in the right-click menu (AXPress while switched
  off, as justhide does).

## 6. Sources

- Repos (in `research/repos/`):
  - Thaw `origin/feat/thaw-3-alpha-10` (4c044b5, 2026-10-16), CHANGELOG
    3.0.0-alpha.7 … alpha.10;
  - Pelmet (`fif7y_pliss`, 0.3.x);
  - `ronny_ellipsis`, `chlee1001_barnook` (Apache-2.0);
  - `hidden` (Hidden Bar 1.11, #420);
  - `cshariq_Sapphire`, `jacklandrin_OnlySwitch`, `PathGao_kururu`,
    `benjustjammin_justhide`, `happy666End_MenuBarHider`, Ice.
- Issues:
  - [Pelmet #81](https://github.com/fif7y/pliss/issues/81), #42, #26;
  - [Thaw #1195](https://github.com/thaw-app/Thaw/issues/1195), #924, #1115,
    #814, #790, #1223;
  - [BarNook PR #17](https://github.com/chlee1001/barnook/pull/17);
  - Hidden Bar #366, #360, #426.
- [Bartender Golden Gate release notes](https://www.macbartender.com/goldengate/releases/);
  [Bartender 6 release notes](https://www.macbartender.com/Bartender6/release_notes/).
- MenuShelf `MenuBarManager/NOTES-macos27.md` §1, §4, §8–9, §12–13.
