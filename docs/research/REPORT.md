# Real icons, animated: what's possible on macOS 27

Research for MenuShelf, 2026-10-16, on macOS 27.0.1 (26A434). This was
read-only. I created no status items, wrote no defaults and changed nothing in
the menu bar. Clones are in `research/repos/`. No code was copied from them:
every mechanism below is described in my own words. Line numbers refer to the
revision noted for each repo.

Starting point: `MenuBarManager/NOTES-macos27.md` §8–10 (the spacer and its
safe width band, the native overflow, and v1's stand-in panel + cover + swap).
Those findings are not repeated here.

## TL;DR

- **The user's idea is feasible, but not by animating the box ourselves.**
  On macOS 27, MenuBarAgent already animates the real icons when it is told to
  hide or show an app's items:
  - reveal: an in-place fade of about 130 ms;
  - conceal: a slide toward the chevron of about 450 ms.
  
  The icons are the real ones and sit in their real slots, so popovers open
  under them and spacing is native.
- **The switch to flip is a visibility restriction, not a spacer.** It is
  MenuBarAgent's "assessment mode" allow-list (`MBAssessmentModeAssertion` in
  the private `MenuBarClientCore.framework`). It is now the standard macOS 27
  hiding mechanism, used in the open by Hidden Bar, Pelmet, BarNook,
  Ellipsis, justhide, MenuBarHider, Sapphire, OnlySwitch, Ice PR #995 and
  Thaw 3.
  - It needs no permission and is live (no relaunch).
  - It hides per app, not per item.
  - Known costs (Focus, camera/mic and Now Playing hidden while active; a
    clock click doesn't open Notification Center) have documented workarounds.
- **Route (a), animating the spacer `length` frame by frame, is the wrong
  tool.**
  - Every length change is a MenuBarAgent relayout, which macOS already
    animates. Ice's macOS 27 PR coalesces changes to one per 300 ms for that
    reason.
  - Items leave and enter the overflow one at a time, as each fits.
  - It still has the gap, the dead zones, and no hiding on non-notch displays.
  - A single length step gets the native slide for free, so keep the spacer
    only as a fallback.
- **Route (b), a cover over real icons, is the v1 problem again.**
  - It needs a picture of the bar background, which moves with the wallpaper,
    appearance, Space and transparency settings.
  - The covered icons still take space and still take clicks.
  - Pelmet does use short covers, only to *mask* MenuBarAgent's own
    animation; it does not hide with them.
- **Recommendation:** hide and show with the assertion. Let MenuBarAgent
  animate the real icons. Keep MenuShelf's own chevron and divider as real
  status items that our app animates. Drop the image panel and the cover.
  Keep the v1 spacer as a fallback for when the private class is missing.
  The experiments are in §5.

## 1. Comparison of the open-source managers

"Real-icon animation" asks: when hidden icons come back, do the real icons
move or fade, and who drives it?

| App (license, last commit) | Hiding on macOS 27 | Revealing | Real-icon animation | macOS 27 status |
| --- | --- | --- | --- | --- |
| **Hidden Bar** ([dwarvesf/hidden](https://github.com/dwarvesf/hidden), MIT, 2026-09-19) | Engine chosen by OS (`MenuBarEngineFactory.swift:16-21`). ≤26: separator length `max(500, min(2×widest screen, 10 000))` (`LegacyLengthEngine.swift:45-48`). 27, **direct build only**: `NativeVisibilityEngine` sorts apps by AX x versus the arrow, then holds an assertion that allows Hidden Bar, the visible apps and system codes 0–63; the new assertion is activated before the old one is invalidated (`HBNativeVisibilityShim.m`). | Separator back to 20 pt in one assignment, or drop the assertion (`StatusBarController.swift:287-299`). "Notch Overflow" (#420) is a plain `NSMenu` of **app icons** (not captures) that AXPresses the item. | **None of its own** (see §1a). On 27, MenuBarAgent's native animation. | 1.11 (2026-09-18) hides on 27 in the direct build. The App Store build still hides nothing. Open: clock→NC broken (#410/#421/#437, FB24954202), Now Playing / Live Activities / camera-mic hidden (#437), system items hidden by mistake (#414/#444), separator disappears (#409/#439). Fix PRs #449/#453 relay the clock click. #360: on 27.0, 600 pt lays out, ≥1000 pt is ejected. |
| **Ice** ([jordanbaird/Ice](https://github.com/jordanbaird/Ice), GPL-3, main 2025-09-20) | 10 000 pt divider (`ControlItem.swift:25-28`). Per-item windows via CGS for moving and capture. | Divider back to variable length, **instantly**: no animation API anywhere. Ice Bar = own panel of `CGWindowListCreateImage` captures; a click ⌘-drags the real item into view and clicks it. | **No.** Only the overlay panel fades. | Broken (#954, 42 comments, no maintainer reply). Open PRs: #995 assertion, #980/#997 spacer into native overflow, #1001 disable moves. |
| **Thaw** ([thaw-app/Thaw](https://github.com/thaw-app/Thaw), GPL-3 + section-7 exception for the closed PlatformRuntimeKit; 3.x branch 2026-10-16) | 2.x: 10 000 pt dividers. 3.x: a bar-wide restriction inside the closed kit. The maintainer confirmed it is the same `MBAssessmentModeAssertion` (discussion #737, reply to Sowyu). Optional Control Center "Allow in Menu Bar" writer; `VisibleCC` hidden flag. | **Inline by default: real items back on the bar**, drawn by MenuBarAgent. Thaw Bar (captured glyphs) only when chosen, when overflowed, or when the items don't fit. | **None of its own.** MenuBarAgent's "scaled down and faded" reflow (§1b). | Works in the 3.0 beta (2.x refuses 27). Many reports of jumping icons, flicker and "wallpaper-coloured squares" over items (#687 comments 170, 188, 246). |
| **Dozer** ([Mortennn/Dozer](https://github.com/Mortennn/Dozer), MPL-2.0, 2022-11-01) | Helper item length 10 000 (`HelperStatusIcon.swift:12,43-45`). | Back to the padding length (`:39-41`). | **No.** An `animationEnabled` setting exists (`Constants.swift:19`) but no code reads it. | Broken (#208 "Broken on macOS 27", #202 crash on 26), abandoned. |
| **SaneBar** ([sane-apps/SaneBar](https://github.com/sane-apps/SaneBar), MIT, 2026-09-20) | Delimiter length 10 000 collapsed, 20 expanded (`Core/Services/HidingService.swift:49-68`). | Length back to 20. A "second menu bar" panel shows **app icons** and clicks with AXPress, falling back to CGEvent. | **No.** | Broken on 27 (#182). The 2026-07-01 "sunset" release made it free under MIT, saying 27 "breaks every menu bar manager". |
| **Pelmet** ([fif7y/pliss](https://github.com/fif7y/pliss), GPL-3, 2026-10-05, 865★) | Assertion, allow-list = everything not hidden. Hidden by *membership*; position never changes on hide or show (`docs/CORE-SETS.md`). | Drop the assertion; the item "reappears where it lives, animated by the system". | **Yes, native.** Measured at 60 fps: reveal = hidden group fades in place in about 130 ms (no stagger, no slide); conceal = about 450 ms native slide toward the chevron (`docs/CORE-SETS.md`, M3). Optional "Instant/Smooth/Fade" styles play **over** the native animation using two stills (Screen Recording). | macOS 27 only, shipping (0.3.x). |
| **BarNook** ([chlee1001/barnook](https://github.com/chlee1001/barnook), **Apache-2.0**, 2026-10-12) and **Ellipsis** ([ronny/ellipsis](https://github.com/ronny/ellipsis), **Apache-2.0**, 2026-10-15), sibling projects | Assertion. `docs/phase0.md` records why the large-length divider fails on 27. | Drop the assertion. A floating bar of app icons is an option. | Native. "MenuBarAgent redraws and crossfades for 640–920 ms after the assertion reports active" (`barnook/docs/notification-center-clock.md:203`). | Working. The best-documented measurements; permissive license. |
| **justhide** ([benjustjammin/justhide](https://github.com/benjustjammin/justhide), GPL-3, 2026-10-13) | Default: assertion. Option: flips Control Center's "Allow in Menu Bar" switches (`Sources/MenuBarSwitches.swift`). Fallback: an inflated divider plus a **pool of spacers**, for a wider second display (`Sources/WidthController.swift`). | Drop the assertion / switch back on / shrink the divider. | Assertion: "instant, nothing slides around" (README). CC switches: "the bar animates": going within 0.1 s, gone in about 0.8 s, back in about 0.5 s "in its own slot" (`MenuBarSwitches.swift:20-24`). Spacer: "icons visibly sliding on every toggle" (README). | Working. |
| **MenuBarHider** ([happy666End/MenuBarHider](https://github.com/happy666End/MenuBarHider), MIT, 2026-10-02) | Assertion. Two own separators `|` … `»`; what sits between them is hidden. | Click `»`. | Native (demo GIF). | Working; must run from /Applications. |
| **MenuBarista** ([hreinssondev/MenuBarista](https://github.com/hreinssondev/MenuBarista), MIT, 2026-06-28) | One invisible spacer item, default length 520 pt (`MenuBarMaskController.swift:22,175`). | Hover the menu bar: length set to 0 in one step (`:175`, polled every 80 ms at `:76`). | None of its own; whatever MenuBarAgent does on a length change. | Beta 1–2 era. Same limits as MenuShelf's spacer (NOTES §8–9). |
| **Sapphire**, **OnlySwitch**, **kururu**, **floe**, **baaar** | All load `MenuBarClientCore` and use the assertion (GitHub code search for `MBAssessmentModeAssertion`). | — | Native. kururu's roadmap says to "prefer reusing the system's native animation". | Active (2026-07 to 2026-10). |

Not open source but relevant: Bartender's Golden Gate beta and
BetterTouchTool 6.569+ ("Load Menu Bar Layout") reportedly use "the same API"
([BTT forum](https://community.folivora.ai/t/macos-27-golden-gate-menu-bar-management-broken-solutions-ice-thaw-bartender-barbee-etc/47232)).

### 1a. Did Hidden Bar or Dozer ever animate the real icons?

**No.**
- No timer, `NSAnimation`, `CADisplayLink` or `animator()` acts on
  `statusItem.length` in Hidden Bar, Dozer, Ice, SaneBar or Thaw 2.x.
  `git log -G animat` in Hidden Bar finds nothing.
- Each sets the length in one assignment.
- The "slide" people remember from ≤26 was AppKit/WindowServer moving each
  item's own window when the separator's length changed. That window no longer
  exists on 27.
- Since no app ever shipped a frame-by-frame length tween, route (a) has no
  proven recipe behind it.

On 27, the only motion of real icons comes from MenuBarAgent:
- Ellipsis: it "animates a new layout for about a second" after the allow-list
  changes (`ellipsis/docs/plan.md:108`, which also re-positions its own panel
  400 ms after opening for that reason).
- Pelmet's 60 fps measurements in §2.

### 1b. Thaw 3 details

Refs read: `origin/feat/thaw-3-alpha-10` (4c044b5, 2026-10-16) and
`3.0.0-beta.2`. PlatformRuntimeKit was not opened.

**Reveal.**
- **Inline is the default.** Lifting the restriction brings the **real items
  back on the real bar**. Thaw draws nothing for this
  (`Thaw/MenuBar/MenuBarSection.swift:257-307`).
- **Thaw Bar (captured glyphs)** is used only when:
  - the user chooses it;
  - the native overflow is active;
  - or the items would not fit inline (`MenuBarManager.swift:247-256`).
- **Capturing glyphs needs a brief real reveal**, because "macOS 27
  physically removes concealed items from MenuBarAgent"
  (`RevealCaptureRules.swift:15-18`). Batches are 1 item on notch displays
  and 6 elsewhere, because one at a time "shows as icons blinking in and out"
  (`:32-52`).

**Animation.**
- Thaw never animates `length` or the real icons.
- Its comments describe MenuBarAgent's transition as "items scaled down and
  faded" mid-reflow (`MenuBarItemImageCache+Reading.swift:642`).
- A divider width change that lands in a different run-loop turn from the
  assertion swap gives "two MenuBarAgent passes, which animate as two
  reflows" (`ControlItem.swift:862-877`).
- "Writing an unchanged length still costs a MenuBarAgent reflow"
  (`:1000`, `:1016`).
- "Divider reflow cannot hide items"; over-wide items now "just overflow"
  (`MenuBarManager.swift:294`, `ControlItem.swift:994-998`).
- **Note for our own UI:** "macOS 27 NSView animator alpha finishes in one
  frame regardless of duration". Thaw uses `CABasicAnimation` on the layer
  instead (`Panels/Appearance/MenuBarOverlayPanel.swift:580-600`).

**Covers, used only for the clock bridge.**
- To let a clock click open Notification Center, Thaw drops the restriction
  for about 1 s. Concealed items then draw to the left of the visible ones;
  the visible ones stay put because the bar is right-anchored
  (`ClockBridgeCover.swift:12-44`).
- A cover hides that band:
  - level `.mainMenu + 1`, `sharingType = .none`;
  - a 32 pt left fade mask;
  - held 1000 ms after the restriction returns, at most 4 s.
- The cover's backdrop is a SkyLight composite of the windows below the menu
  bar level, so no ScreenCaptureKit indicator shows (`MenuBarBackdrop.swift:12-18`).
- But "the bar's blur and tint belong to no window", and glass "captures as
  flat grey". Thaw therefore paints its own fills over a blurred wallpaper
  strip (`ClockBridgeCoverStyle.swift:10-13`).
- That is direct evidence for route (b)'s fidelity problem.

**Opening a concealed item** (`MenuBarItemManager+ConcealedClick.swift:15-140`),
cheapest method first:
1. AX-press the parked element (nothing appears in the bar).
2. Reveal that one item in place, wait 400 ms, click its live frame, then
   conceal again.

"Moving beside Thaw is unsafe: the agent refuses the concealed move back"
(`ConcealedItemOpenMethod.swift:10-19`).

**Settle constants** (`Constants.swift:100-135`):

| Constant | Value |
| --- | --- |
| reveal settle before click | 400 ms |
| native mutation settle | 900 ms |
| layout-table write probe | 700 ms |

**Layout table.**
- Thaw says MenuBarAgent "silently drops most writes" and ignores
  cross-process writes until the owner's layout is invalidated. Thaw forces
  that with a 16 ms length nudge (`ControlItem.swift:1146-1214`).
- It also notes "the agent ignores the new weight when re-allowing an item"
  (`Moving.swift:944`).
- This agrees with Pelmet: the order table is not a hiding tool.

**Thaw 2.x** (`development`):
- 10 000 pt dividers, set directly with no animation;
- extra 10 000 pt spacers above 5120 px;
- refuses to run on 27 (`MacOSCompatibilityWarning.swift:11-17`).

## 2. What macOS 27 does when items change (evidence)

- **One window, no per-item windows** (NOTES §1, Ellipsis `docs/phase0.md`).
  An app's `NSStatusItem` window is only a proxy.
- **An item that is too long is ejected, not clamped.** justhide measured, on
  one bar:
  - laid out up to 671 pt;
  - "clipped" (partial, unreliable) from 737 to 968 pt;
  - ejected from 975 pt (`Sources/CollapseCalibrator.swift:7-27`).

  This matches the dead zones in NOTES §8.
- **Without a notch, the spacer doesn't hide at all.** On notchless displays
  MenuBarAgent "draws items that do not fit on top of the wide item. It never
  pushes an item off-screen. Nothing goes into an overflow menu"
  (Ellipsis `docs/phase0.md`, three external displays). This explains the Dell
  result in NOTES §10.
- **Relayouts are animated by MenuBarAgent**, and no app can turn that off
  (Pelmet `docs/FAQ.md`). Measured examples:

  | Change | What the real icons do | Source |
  | --- | --- | --- |
  | Assertion lifted (reveal), grouped hidden set | Fade in place, about 130 ms, no slide | Pelmet `docs/CORE-SETS.md` M3 |
  | Assertion applied (conceal) | Slide toward the chevron, about 450 ms | same |
  | Hidden item sitting inside the visible cluster | Reveal opens a gap by sliding neighbours about 60 pt over about 400 ms; conceal slides out about 200 ms, then the cluster drifts about 600 ms | same |
  | Own status item added or resized in the same pass | "Everything slides in from the chevron (about 200 ms) then drifts about 300 ms" | Pelmet `docs/HELPER-PROCESS-PLAN.md:16-20` |
  | Control Center switch off / on | Starts within 0.1 s, gone in about 0.8 s / back in about 0.5 s, in its own slot | justhide `MenuBarSwitches.swift:20-24` |
  | Assertion active → drawn state settled | Redraw + crossfade 640–920 ms | BarNook `notification-center-clock.md:203` |
  | Allow-list change → layout stops moving | "Animates a new layout for about a second" | Ellipsis `docs/plan.md:108` |
  | Rapid toggles of overflow | "Fading remnants"; changes coalesced to one per 300 ms "so rapid clicks don't stack overflow animations" | Ice PRs #980, #997 |

  The sources disagree on how the reveal looks and how long it takes:
  - justhide's README calls the assertion "instant, nothing slides around";
  - Pelmet measured a 130 ms fade in place;
  - BarNook and Ellipsis measured how long the layout takes to *settle*:
    0.6–1 s.

  Most likely the visible fade is short, and neighbours keep drifting for a
  while when the gaps change. §5 E1 settles it.
- **Order.** Pelmet found the stored layout table ignored for *live* items,
  read only when the agent restarts, and that only a real HID ⌘-drag reorders
  (`docs/CORE-SETS.md`, "What we verified"). Thaw says writes re-sort the bar
  (#687 comment 365). The sources disagree; it doesn't matter for hiding.
- **Newly created status items land far left.** "Preferred Position" is
  ignored for items macOS hasn't placed itself (justhide
  `SpacerPlacement.swift:18-21`; NOTES §8 agrees). Items keep a stable slot
  only if they get an `autosaveName` at creation.

## 3. The routes

### (a) Animate the spacer's `length` frame by frame (Hidden Bar style)

**What actually happens on 27.**
- The spacer's right edge is fixed and it grows leftward (NOTES §9).
- MenuBarAgent lays items out right to left. Items left of the spacer that
  don't fit go into the overflow, all or nothing per item.
- So while the length shrinks, hidden items don't slide in from off-screen as
  they did on ≤26. Each stays in the overflow until there is room for its
  *whole* width plus the arrow. Then it appears at the boundary (the notch
  edge, or the end of the app menus) and rides right with the spacer's left
  edge.
- The result is items popping out of the notch one at a time, then sliding,
  with Apple's « moving and finally disappearing.

**Each step is a relayout, and relayouts are animated.**
- At 60 fps, every frame retargets MenuBarAgent's own 200–450 ms animation.
  Ice's 27 PR throttles to one change per 300 ms to stop animations stacking,
  and saw "fading remnants" with rapid toggles.
- Expect stutter and visible lag behind the requested length, not a smooth
  tween. MenuBarAgent CPU load is unmeasured.

**The overflow transition itself is MenuBarAgent's fade, and an app can't
control it.**
- The PWB97 Ice fork (the work behind PR #980,
  [`MACOS27.md`](https://github.com/PWB97/Ice/blob/codex/macos-27/MACOS27.md)
  and `docs/rapid-toggle-review-2026-09-05.md`) resizes an Ice-owned blank
  item into the native overflow. It reports that "native overflow can leave
  fading icons" on clicks about 90–116 ms apart.
- "The zero-duration animation experiment did not fix this", so wrapping the
  length change in a zero-duration AppKit animation does not stop
  MenuBarAgent's own animation.
- The same fork found that even a 1 pt item "reserves a visible slot". It
  therefore *withdraws* the blank item (`isVisible = false`) when revealed and
  re-inserts it to hide.

**Hidden Bar never animated the length** either (see §1a), so there is no
proven recipe to copy.

**The structural problems stay:**
- the expansion gap and the capped expansion area (NOTES §9);
- the 975 pt ejection (wide displays);
- no hiding at all on notchless displays (Ellipsis phase 0);
- live-resize jumps while open.

justhide shows a partial fix for multiple displays: a pool of spacers, each
under the cap, created in a fixed order so they land in the push zone.

**Verdict.** Not the way to get "real icons + slide + fade".
- One length step (W→0 and back) already gets MenuBarAgent's native slide
  ("icons visibly sliding on every toggle", justhide).
- That is a reasonable **fallback** when the assertion is unavailable. It is
  not the primary path.
- Experiment E5 measures single step vs. tween so this is settled with
  numbers.

### (b) A cover window with a copy of the bar background, fading over the box

**Background fidelity.** On 26/27 the bar is mostly transparent over the
wallpaper. Text colour adapts to wallpaper luminance, and there are options
like "Show menu bar background" and Reduce Transparency. A cover must
reproduce the pixels under it:
- **Wallpaper only:** Ice crops the wallpaper window (on 27 owned by
  WindowManager, not Dock, per Ice PR #1001) and re-samples every 5 s,
  because there is no wallpaper-change notification.
- **A still of the empty bar:** Pelmet takes this with ScreenCaptureKit
  (Screen Recording).

A third option is Thaw's SkyLight composite of the windows below the bar. It
avoids the recording indicator, but "the bar's blur and tint belong to no
window", and glass captures "as flat grey" (§1b), so no capture reproduces
the bar exactly.

All of these go stale with dynamic or aerial wallpapers, Space switches,
light/dark changes and full-screen menu bars. Thaw's own overlay produced
"wallpaper-colour squares" with items "behind" them (#687 comment 246).
BarNook found the system's default window animation zooming its cover by
about 15 pt until it set `animationBehavior = .none`
(`notification-center-clock.md:285`).

**Space.** Covered icons still take their full width, so on a notch bar they
push other items into the native overflow. "Hidden" doesn't free room, which
is the main reason anyone hides icons on a MacBook.

**Clicks.**
- A click-catching cover makes the box dead space.
- A click-through cover lets invisible items be clicked, and hover tooltips
  still appear.

Either way, the cover appears in screenshots and recordings. It must follow
auto-hide and full-screen bar slides, which cannot be synchronised exactly.

**Verdict.** Not viable as the hiding mechanism. It also breaks the user's
"no copies, no images" rule. Worth keeping only as a **short mask** (≤0.5 s)
if MenuBarAgent's native animation needs hiding in one specific case, as
Pelmet and BarNook do for clock clicks.

### (c) A live, system-level hide/show mechanism

Inventory, from what the open projects document and what I listed read-only
on this Mac:

| Mechanism | Live? | Granularity | Native animation | Permission / cost | Verdict |
| --- | --- | --- | --- | --- | --- |
| **`MBAssessmentModeAssertion` + `MBAssessmentModeConfiguration(allowedSystemItems:allowedBundleIdentifiers:)`** (private `MenuBarClientCore`; XPC `com.apple.MenuBarAgent.VisibilityRestrictionServer`) | Yes. Activation is async; the newest assertion wins. | Per app (bundle ID). Apple items by integer code: 2 = Clock, 6 = Wi-Fi, 8 = Control Center; 0–6 follow the public `AEMenuBarItem` order (Ellipsis phase 0). | **Yes**: about 130 ms fade on reveal, about 450 ms slide on conceal | None. The app must run from **/Applications** or its own items are hidden too. Ellipsis says ad-hoc signed works there; Ice PR #995 says Developer ID only. E7 settles it. | **Recommended** |
| Control Center "Allow in Menu Bar" switches: `trackedApplications` in `group.com.apple.controlcenter`, written through the private CF "…WithContainer" preference calls after the user picks the file in an open panel (justhide, Thaw) | Yes, within 0.1 s | Per app (helpers by their own ID, e.g. `com.bjango.istatmenus.status`) | **Yes**: slide out about 0.8 s, back about 0.5 s | File pick plus security-scoped bookmark. System Settings shows the app as off. Crash recovery needed. "On 27.2 beta 26B5091g the switch did nothing visible even by hand." Keeps camera, Focus and the clock→NC click. | Good secondary option, fragile |
| `NSStatusItem VisibleCC <name>` in the owning app's defaults | No, needs relaunch (NOTES §10, verified) | Per item | n/a | Writes other apps' prefs | Rejected (already) |
| `NSStatusItem.isVisible`, length, alpha of **our own** items | Yes | Our items only | Our own animation; joining the layout triggers MenuBarAgent's slide | None | Use for MenuShelf's chevron/divider |
| Layout table `TrailingItemPreferredPositions` | Disputed for live items (§2) | Per item | Re-sort | Protected container (file pick or FDA) | Only for ordering, not needed |
| `MBMenuBarItemManager` (`setItems:`, `setGloballyHidden:`, `requestMenuBarVisibility:…`), `MBHideAttachedAVModuleAssertion`, `MBUtilities` (`listMenuBarItemsForSpaceID:`) | Unknown | — | — | BarNook: the utilities service needs the private entitlement `com.apple.private.menubar.utilities`; the item manager is presumably AppKit's own channel | Don't use |
| Public `AEAssessmentConfiguration.allowedMenuBarItems` (AutomaticAssessmentConfiguration, macOS 27) | Yes | — | — | Apple-granted entitlement; locks the whole Mac into exam mode | Not usable, but shows Apple ships and supports the underlying mechanism |

Class and selector names were confirmed on this Mac (27.0.1, 26A434) by
listing the loaded framework's Objective-C runtime. Nothing was activated.
The configuration has **no animation or duration parameter**, so the
animation is entirely MenuBarAgent's.

**Known costs of the assertion, and the workarounds others found:**
- **Per-app granularity.** Raycast's two items hide together. In edit mode,
  an app with items on both sides of the divider needs a rule ("hidden if
  its leftmost item is in the box").
- **Apple's own extras go while an assertion is held**: Focus, the
  camera/mic indicator (the green button) and Now Playing. Pelmet and justhide
  ship their own replacement items. The Control Center-switch route avoids
  this.
- **A clock click doesn't open Notification Center**, and neither does the
  ⌥N shortcut. MenuBarAgent decides at mouse-down. BarNook: on mouse-down
  over the clock, lift the assertion, replay the click about 10–80 ms later,
  reapply. NC then opens in 409–500 ms instead of about 170 ms. Covers stop
  hidden icons flashing meanwhile. Pelmet adds its own NC shortcut.
- **Always keep one assertion alive.** Activate the new one before
  invalidating the old one, or everything flashes. Retry after
  250 ms / 1 s / 4 s if activation fails (BarNook `spec.md:60`, justhide
  README).
- **The allow-list must track app launches.** A newly launched app is hidden
  until it's listed. `NSWorkspace` launch notifications don't fire for
  `LSUIElement` apps, so observe `runningApplications` instead (justhide
  README).
- **Private API.** Load it with `dlopen`, check each class and selector, and
  fail soft to the spacer.

**Provenance / licence.** MenuShelf's notes avoided this mechanism because
Thaw ships it inside the closed PlatformRuntimeKit, whose licence forbids
reusing what is learned from it. The same calls are now documented
independently and publicly:
- [Sowyu in Thaw discussion #737](https://github.com/thaw-app/Thaw/discussions/737);
- the Apache-2.0 BarNook/Ellipsis `docs/phase0.md` and `docs/spec.md`;
- the MIT Hidden Bar shim;
- and they are visible in the system framework itself.

MenuShelf never touched the kit. Record this provenance in NOTES before
building, and write the shim from the selector names alone. (Not legal
advice.)

### (d) Other ideas found

1. **Hide by membership, not by position** (Pelmet's "sets core").
   - The box is defined by MenuShelf's own divider status item.
   - On Done in edit mode: read AX x positions, and the apps left of the
     divider become the hidden set.
   - Hide or show never moves anything, so there are no drag walks and
     nothing fights the native «.
   - This maps directly onto the user's ⌘-drag box.
2. **Two own separators** (`|` … `»`, MenuBarHider). The `»` is a real,
   allow-listed MenuShelf status item, so its image and press state animate
   with plain AppKit.
   - This replaces the ArrowCatcher over Apple's «.
   - Apple's « then only appears when the bar is genuinely full.
3. **Separate helper bundles for our own items in a section** (Pelmet's
   helper-process plan). Only needed if MenuShelf later adds its own items
   (launchers, separators) that must hide *with* the hidden set. The
   assertion is per bundle and the main app must stay allow-listed.
4. **Spacer pool for multiple displays** (justhide). If the spacer stays as a
   fallback: several spacers, each under the ~670 pt "laid out" cap, created in
   a fixed order between the chevron and the divider. That covers a notch
   MacBook plus a wider external.
5. **Edge feather at the notch** (my idea, untested). If the spacer fallback
   pops items out of the notch one at a time, a 20–30 pt black→clear gradient
   window on the notch's right edge would soften the pop. Black always
   matches the notch. Only for the fallback; probably not worth it.
6. **Covers only to mask, never to hide** (Pelmet, BarNook). If one native
   transition looks wrong (for example the 450 ms conceal slide feels slow),
   a 2–3 frame still can stand in for it. That brings back Screen Recording
   and the v1 fragility, so do it only if E1 shows a real problem.

## 4. Recommendation

**Route (c): the assessment-mode assertion, with MenuBarAgent's native
animation.** MenuShelf keeps a few real status items of its own.

```
 notch | [hidden apps …]  |  »  [visible items …]  Clock
                          ^  ^
              MenuShelf divider  MenuShelf chevron (allow-listed, ours)
```

- **Config:** ⌘-drag icons across the divider, exactly as today. Edit mode =
  no assertion, with the divider shown. On Done, the hidden set = the bundle
  IDs of the AX items left of the divider (excluding MenuShelf and the system
  items the user keeps).
- **Hide:** activate an assertion that allows every running bundle except the
  hidden set, plus all system-item codes. MenuBarAgent slides the real icons
  out toward the chevron (about 450 ms) and closes the gap.
- **Show:** activate an assertion that allows everything (or invalidate it,
  but see the NC cost), then drop the old one. The real icons fade in place
  (about 130 ms) in their real slots. Popovers open under them, with native
  spacing.
- **Close rules:** unchanged from v1 (click outside or on », no timer).
- **Our chevron:** our own `NSStatusItem`. Its »/« image change and any
  pressed-capsule animation are ours. Animate them with `CABasicAnimation` on
  the layer, not `animator().alphaValue`, which completes in one frame on 27
  (Thaw).
- **One agent pass:** make any change to our own items (chevron image,
  divider visibility) in the **same run-loop turn** as the assertion swap.
  Two separate passes animate as two reflows (Thaw).
- **Opening a hidden item while concealed** (from search or a hotkey):
  AXPress the parked element first. If that fails, reveal just that app
  (an allow-list that includes it), wait about 400 ms, then press
  (Thaw's order). The ArrowCatcher, RevealPanel,
  ItemImageCache and cover all go. Screen Recording is no longer needed.
- **Fallback:** if the class or selectors are missing or activation fails, or
  the user opts out of private API, use the v1 spacer with a **single** length
  step.
- **Optional:** the Control Center-switch mode (justhide/Thaw "Native") for
  users who need the camera/Focus/NC behaviour intact, behind an explicit file
  pick.
- **Cost to accept:** per-app granularity; Focus/camera/Now Playing missing
  while hidden (ship replacement items later, or show everything on those
  events); the clock-click relay. Accessibility is still required (item
  frames), so distribution stays direct and notarized, which v1 already
  assumes.

## 5. Experiments for the build session

All of these touch the menu bar, so run them in the build session, one at a
time. A small standalone probe (for example `scripts/assert-probe.swift`,
built into an `.app` and copied to `/Applications`) is enough for E1–E4 and
E7. For recordings, use a ScreenCaptureKit stream of the bar strip at the
display's refresh rate. `screencapture -v` has no reliable frame timing, per
BarNook.

**E1. Native animation under the assertion.**
- Steps:
  1. Pick two apps left of the divider (for example OrbStack and Stats).
  2. Activate an assertion that excludes them, record 2 s, invalidate,
     record 2 s.
  3. Repeat with the hidden apps (a) adjacent to each other and (b) one of
     them sitting among visible items.
- Measure:
  - time from the call to the first changed frame, and to the completion
    handler;
  - duration and kind of transition (fade / slide / both);
  - whether visible items to the right move;
  - whether Apple's « appears;
  - AX frames before and after.
- Pass: reveal ≤ 200 ms and no stray frames; conceal reads as a slide.

**E2. Swap without flashing.**
- Steps: hold assertion A (hide set), activate B (hide nothing) and only then
  invalidate A. Compare with invalidate-then-activate.
- Measure: whether any frame shows all items, or the clock or others
  flicker.

**E3. Popover alignment after reveal.**
- Steps: after E1's reveal, AXPress Stats, OrbStack and one Apple module
  (Wi-Fi).
- Measure: menu or popover x against the item's AX frame. Expect alignment,
  unlike v1's about 200 pt offset.

**E4. Side effects while concealed.**
- Steps: with an assertion held:
  - click the Clock, press ⌥N, open Control Center;
  - start a FaceTime/Photo Booth camera session;
  - set a Focus;
  - play music.
- Measure: which of NC, the green camera button, Focus and Now Playing fail.
- Then try BarNook's relay (lift on mouse-down over the clock, replay the
  click 10–80 ms later, reapply after the panel appears) and measure
  click→NC latency.

**E5. Spacer: single step vs. tween (for the fallback).**
- Steps:
  1. With the current v1 spacer at its hiding width (for example 453 pt):
     set the length to 22 in one step, record, then back to 453.
  2. Then tween over 0.3 s at 60 fps (18 steps), each way.
- Measure:
  - continuous slide vs. one-at-a-time pop-outs;
  - lag between the requested and drawn width;
  - any dropped or ejected frames;
  - Apple « behaviour;
  - MenuBarAgent CPU (`top -pid`).
- This settles the user's question about route (a) with numbers.

**E6. Granularity and edge cases.**
- Steps:
  - Hide Raycast (two items).
  - Launch a new menu bar app while concealed.
  - Quit and relaunch a hidden app.
  - Connect the Dell (non-notch) and repeat E1 there.
- Measure:
  - whether both Raycast items go;
  - whether the new app is wrongly hidden until re-applied;
  - whether hiding works on the external display (it should, since it isn't
    width-based);
  - whether "hidden" frees room so no native overflow appears.

**E7. Signing and location.**
- Run the probe as follows:
  - (a) ad-hoc signed in /Applications;
  - (b) "MenuShel Dev"-signed in /Applications;
  - (c) from `.build/`.
- Measure: whether MenuShelf's own chevron stays visible under the allow-list
  in each case. This resolves the Ellipsis vs. Ice PR #995 disagreement.

**E8. Optional: Control Center switches, read-only first.**
- Steps:
  1. Pick `group.com.apple.controlcenter.plist` in an open panel and dump
     `trackedApplications` only.
  2. Toggle one app by hand in System Settings and diff.
  3. Only then try one write, record the animation, and restore.

**E9. Optional: the cover's fidelity, only if E1 shows a transition worth
masking.**
- Steps: capture the strip excluding MenuBarAgent's windows, and compare it
  with a still of the empty bar in light/dark, with "Show menu bar background"
  on/off and Reduce Transparency on/off.
- Measure: the pixel difference.

## 6. Sources

- MenuShelf: `MenuBarManager/NOTES-macos27.md` §1–10; build hand-over in the
  shared notes folder.
- Issues and discussions:
  - [Thaw #687](https://github.com/thaw-app/Thaw/issues/687) (437 comments);
  - [Thaw discussion #737](https://github.com/thaw-app/Thaw/discussions/737),
    especially Sowyu's 2026-07-25 comment and the maintainer's reply;
  - [Ice #954](https://github.com/jordanbaird/Ice/issues/954) and PRs #980,
    #995, #997, #1001.
- Articles: [Badgeify: macOS 27 menu bar changes](https://badgeify.app/macos-27-golden-gate-menu-bar-changes/);
  [BTT community thread](https://community.folivora.ai/t/macos-27-golden-gate-menu-bar-management-broken-solutions-ice-thaw-bartender-barbee-etc/47232).
- Repos (cloned in `research/repos/`): hidden, Ice, Thaw, Dozer, MenuBarista,
  SaneBar, fif7y_pliss (Pelmet), ronny_ellipsis (also `ellipsis/`),
  chlee1001_barnook,
  benjustjammin_justhide, happy666End_MenuBarHider, cshariq_Sapphire,
  PathGao_kururu, ovidijusr_floe, bylaaabs_baaar.
