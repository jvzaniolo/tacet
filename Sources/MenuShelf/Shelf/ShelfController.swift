import AppKit
@preconcurrency import ApplicationServices

/// MenuShelf v1: hide with the spacer, reveal in our own panel, one arrow.
///
/// - The spacer pushes everything left of it into macOS's overflow.
/// - macOS then shows its overflow arrow at the spacer's right end. That arrow
///   is our only arrow: ArrowCatcher sits on top of it and takes its clicks,
///   so macOS's own expansion never runs.
/// - Clicking opens RevealPanel with the hidden items (cached images, so it is
///   instant).
/// - Clicking an item hands off to the real bar ("revealed"): the hidden items
///   come back onto the bar under an opaque copy of the bar background, the
///   panel's icons slide onto them and fade, and the real item is pressed, so
///   its menu opens right under it. The bar stays revealed until a click
///   outside it and its menus, Esc with no menu open, or a click on ».
///   (`pressMode ax` instead presses items from the panel without revealing.)
/// - Closing copies the native overflow: click outside or on the arrow; no timer.
@MainActor
final class ShelfController {
    private let spacer = HidingSpacer()
    private let catcher = ArrowCatcher()
    private let panel = RevealPanel()
    private let images = ItemImageCache()
    private let editHint = EditHint()

    private var snapshot = BarReader.Snapshot(arrow: nil, spacer: nil, hidden: [], visible: [])
    /// The display whose menu bar holds our spacer, and its leading boundary.
    private var barScreen: BarReader.ScreenInfo?
    private var boundary: CGFloat = 0
    /// Debug only (`--debug`): freezes the automatic width.
    private var widthFrozen = false
    private var refreshTimer: Timer?
    private var refreshPending = false
    private var refreshing = false
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// The item whose menu we opened from the panel, while it is open.
    private var tracker: MenuTracker?
    private var trackTimer: Timer?
    private var restoreAfterPress = false
    private let barCapture = BarCapture()
    private let cover = CoverWindow()
    /// Windows the hidden items' apps had on screen when we revealed them;
    /// anything newer is one of their menus or popovers.
    private var revealBaseline: Set<CGWindowID> = []
    private var revealedPIDs: Set<pid_t> = []
    private var lastPick: (key: String, at: Date)?
    private var lastCapturedArrow: CGRect?
    private var lastKnownArrow: CGRect? {
        get { (UserDefaults.standard.string(forKey: "lastArrow")).map { NSRectFromString($0) } }
        set { UserDefaults.standard.set(newValue.map { NSStringFromRect($0) }, forKey: "lastArrow") }
    }

    var openPermissions: (() -> Void)?
    var openDiagnostics: (() -> Void)?

    private static let didEditLayoutKey = "didEditLayoutOnce"

    func start() {
        catcher.onClick = { [weak self] in self?.togglePanel() }
        catcher.onRightClick = { [weak self] event in self?.showMenu(at: NSEvent.mouseLocation) }
        panel.onPick = { [weak self] item in self?.pick(item) }
        editHint.onDone = { [weak self] in self?.finishEditing() }
        spacer.item.button?.target = self
        spacer.item.button?.action = #selector(spacerClicked)

        // React quickly when our spacer moves (⌘-drag, relayout), and poll
        // slowly for everything else (apps adding items, text items resizing).
        if let window = spacer.item.button?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        if CommandLine.arguments.contains("--debug") { installDebugCommands() }

        if !UserDefaults.standard.bool(forKey: Self.didEditLayoutKey) {
            // First run: the divider starts leftmost, so nothing is hidden yet.
            beginEditing()
        } else {
            refresh()
        }
    }

    // MARK: Refresh

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        guard AX.isTrusted(prompt: false), !refreshing else { return }
        refreshing = true
        let length = spacer.length
        let screens = BarReader.screens()
        Task.detached(priority: .userInitiated) {
            let snap = BarReader.snapshot(spacerLength: length)
            let screen = BarReader.screen(for: snap.spacer ?? snap.arrow, in: screens)
            let boundary = BarReader.leadingBoundary(on: screen)
            await MainActor.run { self.apply(snap, screen: screen, boundary: boundary) }
        }
    }

    private func apply(_ snap: BarReader.Snapshot, screen: BarReader.ScreenInfo?, boundary: CGFloat) {
        refreshing = false
        var snap = snap
        // macOS sometimes leaves its arrow out of AX for a while (seen for
        // minutes after a relaunch) although items are visibly parked in the
        // overflow. Then fall back to where the arrow last was.
        if snap.arrow == nil, let spacerFrame = snap.spacer {
            let parked = snap.visible.filter { f in f.frame.map { spacerFrame.insetBy(dx: 2, dy: -20).contains(CGPoint(x: $0.midX, y: spacerFrame.midY)) } ?? false }
            if !parked.isEmpty, let parkedRight = parked.compactMap({ $0.frame?.maxX }).max() {
                // Parked items stack just left of the arrow (measured: arrow
                // minX ≈ rightmost parked edge − 10 pt, 17.5 × 36 pt).
                let derived = CGRect(x: parkedRight - 10, y: barTop + 1, width: 17.5, height: 36)
                let last = lastKnownArrow.flatMap { abs($0.minX - derived.minX) < 4 ? $0 : nil }
                snap.arrow = last ?? derived
                snap.hidden = parked
                snap.visible.removeAll { item in parked.contains { $0.id == item.id } }
            }
        }
        if let arrow = snap.arrow { lastKnownArrow = arrow }
        snapshot = snap
        barScreen = screen
        self.boundary = boundary
        guard !spacer.isEditing else { catcher.cover(arrow: nil); return }
        // While revealed (or moving there or back) the catcher stays put over
        // the old arrow spot, drawing ».
        guard phase == .hidden || phase == .panel, !spacer.isRevealed else { return }
        guard !restoreAfterPress, !widthFrozen else { catcher.cover(arrow: snap.arrow); return }
        if let frame = snap.spacer,
           spacer.fit(spacerFrame: frame, arrow: snap.arrow, boundary: boundary, others: (snap.hidden + snap.visible).compactMap(\.frame)) {
            scheduleRefresh()
        }
        catcher.cover(arrow: snap.arrow)
        if phase == .panel, snap.arrow == nil { closePanel() }
        // Keep the bar background and the native arrow glyph fresh for the
        // open state, while nothing of ours is drawn over the bar.
        if !panel.isOpen {
            let moved = snap.arrow.map { a in lastCapturedArrow.map { abs($0.minX - a.minX) > 0.5 } ?? true } ?? false
            if moved { lastCapturedArrow = snap.arrow }
            barCapture.refreshIfNeeded(screen: screen, arrow: snap.arrow, force: moved)
        }
    }

    // MARK: Panel and reveal
    //
    // hidden ─click » ─▶ panel (our icons spring in from cache, instant)
    //   └ after the spring: cover the bar, let the real items back in under
    //     the cover, wait for macOS to finish moving them ─▶ swap: our panel
    //     and cover vanish over the identical real icons ─▶ revealed (native
    //     clicks and menus). Clicks on our icons before the swap are queued.
    // revealed ─outside click / Esc / » ─▶ closing: our panel reappears over
    //   the real icons, they go back into the overflow under the cover, and
    //   our panel plays the open animation in reverse ─▶ hidden.
    // Without Screen Recording there is no cover: the panel stays and items
    // are pressed from it (pressMode ax behaviour).

    private enum Phase { case hidden, panel, revealing, revealed, closing }
    private var phase: Phase = .hidden
    private var phaseToken = 0
    private var pendingPick: MenuBarItem?
    private var closeRequested = false
    /// The arrow's AX frame when we revealed; the catcher stays there.
    private var revealArrow: CGRect?
    /// Keys of the items we revealed (not whole apps: one app can have an
    /// item on each side of the divider).
    private var revealedKeys: Set<String> = []

    private var nativeReveal: Bool {
        (UserDefaults.standard.string(forKey: "pressMode") ?? "native") == "native"
    }

    private func togglePanel() {
        switch phase {
        case .hidden: openPanel()
        case .panel: closePanel()
        case .revealing: cancelReveal()
        case .revealed: conceal()
        case .closing: break
        }
    }

    private func entries(for items: [MenuBarItem]) -> [RevealPanel.Entry] {
        items.map { item in
            let key = BarReader.key(for: item)
            if let image = images.image(for: key) { return .init(item: item, image: image, isCaptured: true) }
            if ItemImageCache.canCapture {
                // Never photographed yet: an empty slot of its width, so at
                // the swap the real icon just appears instead of morphing.
                let width = item.frame?.width ?? 24
                return .init(item: item, image: NSImage(size: NSSize(width: width, height: 24)), isCaptured: true)
            }
            let icon = NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            return .init(item: item, image: icon, isCaptured: false)
        }
    }

    private var barTop: CGFloat { barScreen?.axTop ?? 0 }
    private func barHeight(for arrow: CGRect) -> CGFloat { max(((arrow.midY - barTop) * 2).rounded(), 24) }

    /// The stretch of bar our cover hides: from the notch / app menus to just
    /// left of the arrow (the catcher covers the arrow itself).
    private func coverRectAX(arrow: CGRect) -> CGRect {
        let left = boundary + 1
        return CGRect(x: left, y: barTop, width: max(ArrowCatcher.coverRectAX(for: arrow).minX - left, 0), height: barHeight(for: arrow))
    }

    private func openPanel() {
        guard phase == .hidden, let arrow = snapshot.arrow else { return }
        phaseToken += 1
        let token = phaseToken
        pendingPick = nil
        closeRequested = false
        let hidden = sortedHidden()
        panel.open(entries: entries(for: hidden), arrow: arrow, boundary: boundary, barTop: barTop,
                   barHeight: barHeight(for: arrow), naturalX: images.order, absoluteX: expectedPositions(of: hidden, arrow: arrow))
        catcher.setOpen(true, cover: barCapture.expandedArrow)
        // A fresh copy of the bar for the cover, taken while the spring plays
        // (our windows are excluded from it).
        barCapture.refreshIfNeeded(screen: barScreen, arrow: arrow, force: true, updateArrow: false)
        catcher.bringToFront()
        phase = .panel
        installPanelMonitors()
        if nativeReveal {
            DispatchQueue.main.asyncAfter(deadline: .now() + RevealPanel.openDuration) { [weak self] in
                self?.beginReveal(token: token, arrow: arrow)
            }
        }
    }

    private func closePanel(animated: Bool = true, dismissMenu: Bool = true) {
        // Past the panel stage the real items are on (or entering) the bar.
        if phase == .revealing { cancelReveal(); return }
        if phase == .revealed { conceal(); return }
        if dismissMenu { tracker?.dismiss() }
        endTracking()
        phaseToken += 1
        if phase == .panel || phase == .hidden {
            panel.close(animated: animated)
            catcher.setOpen(false)
            phase = .hidden
        }
        removeMonitors()
    }

    /// Hidden items in last-seen bar order (left to right).
    private func sortedHidden() -> [MenuBarItem] {
        snapshot.hidden.enumerated().sorted { a, b in
            let ka = images.order[BarReader.key(for: a.element)] ?? CGFloat(a.offset) - 10000
            let kb = images.order[BarReader.key(for: b.element)] ?? CGFloat(b.offset) - 10000
            return ka < kb
        }.map(\.element)
    }

    /// Where macOS will put `items` when revealed: right-aligned against the
    /// arrow with the gap measured at the last reveal, using the real spacing
    /// between items (from the last time they were on the bar). Exact as long
    /// as the set of hidden items hasn't changed.
    private func expectedPositions(of items: [MenuBarItem], arrow: CGRect) -> [String: CGFloat] {
        let keys = items.map(BarReader.key(for:))
        guard let lastKey = keys.last else { return [:] }
        let gapToArrow = CGFloat(UserDefaults.standard.object(forKey: "revealGap") as? Double ?? 30)
        let lastWidth = images.image(for: lastKey)?.size.width ?? items.last?.frame?.width ?? 24
        let lastX = arrow.minX - gapToArrow - lastWidth
        // Best: the real positions from the last time these items were on the
        // bar, shifted so the last one sits where macOS will put it.
        if keys.allSatisfy({ images.order[$0] != nil }), let lastOrder = images.order[lastKey] {
            let shift = lastX - lastOrder
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, (images.order[$0]! + shift).rounded()) })
        }
        // Otherwise pack them right-aligned with 4 pt between items.
        var result: [String: CGFloat] = [:]
        var x = lastX
        for (item, key) in zip(items, keys).reversed() {
            let width = images.image(for: key)?.size.width ?? item.frame?.width ?? 24
            if key != lastKey { x -= width + 4 }
            result[key] = x.rounded()
        }
        return result
    }

    /// Lets the real items back onto the bar under a cover, then swaps.
    private func beginReveal(token: Int, arrow: CGRect) {
        guard phase == .panel, token == phaseToken else { return }
        let rect = coverRectAX(arrow: arrow)
        guard cover.show(barCapture.backgroundPatch(for: rect), over: rect, fadeIn: 0.1) else {
            Log.write("Reveal: no bar capture (Screen Recording off?); staying in panel mode")
            return
        }
        panel.bringToFront()
        catcher.bringToFront()
        phase = .revealing
        revealArrow = arrow
        let hidden = snapshot.hidden
        revealedPIDs = Set(hidden.map(\.pid))
        revealedKeys = Set(hidden.map(BarReader.key(for:)))
        revealBaseline = Set(revealedPIDs.flatMap { MenuTracker.windows(of: $0).map(\.id) })
        let parked = Dictionary(hidden.compactMap { item in MenuBarEnumerator.frame(of: item.element).map { (BarReader.key(for: item), $0.minX) } },
                                uniquingKeysWith: { a, _ in a })
        let started = Date()
        // Let the cover fade in fully before anything moves underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            guard let self, token == self.phaseToken else { return }
            self.spacer.setRevealed(true)
            self.waitForLayout(of: hidden, parked: parked, since: Date()) { [weak self] frames in
                self?.revealSettled(frames: frames, items: hidden, token: token, started: started)
            }
        }
    }

    private func revealSettled(frames: [String: CGFloat], items hidden: [MenuBarItem], token: Int, started: Date) {
        do {
            guard token == phaseToken else { return }
            // AX reports the final layout at once; macOS animates to it for
            // ~0.3 s more. Swap only once that animation is over.
            let wait = max(0, 0.56 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, token == self.phaseToken else { return }
                self.completeReveal(frames: frames, items: hidden, since: started)
            }
        }
    }

    /// Close requested before the swap: the real items are still under the
    /// cover, so send them back and let the panel animate out on top.
    private func cancelReveal() {
        guard phase == .revealing else { return }
        phaseToken += 1
        let token = phaseToken
        phase = .closing
        removeMonitors()
        catcher.setOpen(false, cover: barCapture.collapsedArrow)
        spacer.setRevealed(false)
        panel.close(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, token == self.phaseToken else { return }
            self.cover.hide(fade: 0.1)
            self.catcher.setOpen(false)
            self.revealedPIDs = []
            self.revealedKeys = []
            self.revealBaseline = []
            self.phase = .hidden
            self.scheduleRefresh()
        }
    }

    private func completeReveal(frames: [String: CGFloat], items: [MenuBarItem], since: Date) {
        // Learn where macOS put them, so the next open lands exactly there.
        if let arrow = revealArrow {
            let rightEdges = items.compactMap { MenuBarEnumerator.frame(of: $0.element)?.maxX }
            if let last = rightEdges.max() {
                let gap = arrow.minX - last
                if gap > 0, gap < 80 { UserDefaults.standard.set(Double(gap), forKey: "revealGap") }
                let predicted = panel.itemFrames.map { $0.frame.minX }.min() ?? 0
                Log.write("Reveal: gap to arrow \(Int(gap)) pt; panel→real shift \(Int((frames.values.min() ?? predicted) - predicted)) pt")
            }
        }
        let planned = Dictionary(panel.itemFrames.map { (BarReader.key(for: $0.item), $0.frame.minX) }, uniquingKeysWith: { a, _ in a })
        Log.write("Reveal: planned vs real " + frames.sorted { $0.value < $1.value }.map { "\($0.key.split(separator: "|").last ?? ""): \(Int(planned[$0.key] ?? -1))→\(Int($0.value))" }.joined(separator: ", "))
        // These positions were verified settled: the reference for next time.
        images.rememberPositions(frames)
        panel.moveItems(toAX: frames, duration: 0)
        // Same icons at the same spots underneath: a quick cross-fade hides
        // the small rendering differences between our pictures and the bar.
        panel.handOff(duration: 0.12)
        cover.hide(fade: 0.12)
        catcher.bringToFront()
        phase = .revealed
        Log.write("Revealed natively in \(Int(Date().timeIntervalSince(since) * 1000)) ms")
        installRevealedMonitors()
        if let pick = pendingPick {
            pendingPick = nil
            Self.pressAsync(pick)
        }
        if closeRequested { closeRequested = false; conceal(); return }
        // The real icons are on screen: refresh images and positions so the
        // panel matches them exactly next time.
        let length = spacer.length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.phase == .revealed else { return }
            Task { @MainActor in
                let snap = await Task.detached { BarReader.snapshot(spacerLength: length) }.value
                let screen = BarReader.screen(for: snap.spacer, in: BarReader.screens())
                await self.images.capture(snap.visible, on: screen)
            }
        }
    }

    /// Close rules while our panel is up, copied from the native overflow
    /// (NOTES §8): a click outside the panel *and* outside the menu of the item
    /// we opened, a click on the arrow, or Esc while no menu is open. No timer.
    private func installPanelMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.phase == .panel || self.phase == .revealing else { return }
                if self.catcher.frame.contains(location) || self.panel.frame.contains(location) {
                    // A tracking NSMenu (no-cover fallback) swallows the click
                    // that dismisses it, so our item never sees it: replay it.
                    if let tracker = self.tracker, tracker.isTrackingMenu,
                       let hit = self.panel.itemFrames.first(where: { $0.frame.contains(location) }),
                       BarReader.key(for: hit.item) != BarReader.key(for: tracker.item) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pick(hit.item) }
                    }
                    return
                }
                if let tracker = self.tracker, tracker.contains(cocoaPoint: location) { return }
                if self.phase == .revealing { self.cancelReveal(); return }
                // The click also dismisses the item's menu by itself.
                self.closePanel(dismissMenu: false)
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, Date() > MenuTracker.injectingEscapeUntil else { return }
                if self.phase == .revealing { self.cancelReveal(); return }
                guard self.phase == .panel else { return }
                // Esc with a menu open belongs to that menu; the panel stays.
                if let tracker = self.tracker, tracker.isOpen { return }
                self.closePanel()
            }
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
    }

    // MARK: Opening an item

    /// Opens `item`'s menu, only ever on a click (never on hover).
    private func pick(_ item: MenuBarItem) {
        let key = BarReader.key(for: item)
        // A replayed click and the real one can both arrive: keep one.
        if let lastPick, lastPick.key == key, Date().timeIntervalSince(lastPick.at) < 0.3 { return }
        lastPick = (key, Date())
        if nativeReveal, phase == .panel || phase == .revealing, cover.isShown || barCapture.background != nil {
            // The real item is about to be on the bar: press it there.
            pendingPick = item
            panel.setPressed(item)
            return
        }
        if UserDefaults.standard.string(forKey: "pressMode") == "reveal" {
            closePanel(animated: false)
            pressRevealed(item)
        } else {
            pickInPanel(item)
        }
    }

    /// AXPress can block until the app's menu finishes opening (or time out,
    /// ~1–2 s with "cannot complete"); never do it on the main thread.
    nonisolated static func pressAsync(_ item: MenuBarItem) {
        let element = item.pressElement
        let name = item.displayName
        DispatchQueue.global(qos: .userInteractive).async {
            AXUIElementSetMessagingTimeout(element, 0.5)
            let result = AX.press(element)
            Log.write("Open \(name) on the bar: AXPress → \(result.rawValue)")
        }
    }

    /// Polls the items' AX frames until macOS has moved them off their parked
    /// overflow spot and they stopped moving (or 0.9 s), then reports their
    /// x positions by key.
    private func waitForLayout(of items: [MenuBarItem], parked: [String: CGFloat], since: Date,
                               previous: [String: CGFloat]? = nil, done: @escaping ([String: CGFloat]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            var frames: [String: CGFloat] = [:]
            for item in items {
                if let f = MenuBarEnumerator.frame(of: item.element) { frames[BarReader.key(for: item)] = f.minX }
            }
            let moved = frames.contains { abs((parked[$0.key] ?? $0.value) - $0.value) > 1 }
            let stable = previous.map { prev in frames.allSatisfy { abs((prev[$0.key] ?? -1) - $0.value) < 0.5 } } ?? false
            let elapsed = Date().timeIntervalSince(since)
            if (moved && stable) || elapsed > 0.9 {
                done(frames)
            } else {
                self?.waitForLayout(of: items, parked: parked, since: since, previous: frames, done: done)
            }
        }
    }

    /// While revealed, the bar behaves natively. We only watch for the end:
    /// a click outside the revealed stretch of bar and outside any menu or
    /// popover, Esc with no menu open, or a click on ».
    private func installRevealedMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.phase == .revealed else { return }
                if self.catcher.frame.contains(location) { return }
                if self.isInRevealedBar(location) || self.isInItemMenu(location) { return }
                self.conceal()
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, self.phase == .revealed, !self.isAnyItemMenuOpen() else { return }
                self.conceal()
            }
        }
    }

    private func isInRevealedBar(_ point: NSPoint) -> Bool {
        guard let window = spacer.item.button?.window else { return false }
        let bar = window.frame
        // From the notch / app menus to the » (the spacer's right edge).
        return point.y >= bar.minY - 2 && point.y <= bar.maxY + 2 && point.x >= boundary - 2 && point.x <= bar.maxX + 2
    }

    private func itemMenuWindows() -> [MenuTracker.OwnerWindow] {
        revealedPIDs.flatMap { MenuTracker.windows(of: $0) }.filter { !revealBaseline.contains($0.id) || $0.isMenu }
    }

    private func isInItemMenu(_ point: NSPoint) -> Bool {
        let ax = CGPoint(x: point.x, y: BarReader.primaryHeight - point.y)
        return itemMenuWindows().contains { $0.bounds.insetBy(dx: -2, dy: -2).contains(ax) }
    }

    private func isAnyItemMenuOpen() -> Bool { !itemMenuWindows().isEmpty }

    /// revealed → hidden: our panel reappears over the real icons at their
    /// exact positions, the real items go back into the overflow under the
    /// cover, and the panel plays the open animation in reverse.
    private func conceal() {
        guard phase == .revealed else { return }
        phase = .closing
        phaseToken += 1
        let token = phaseToken
        removeMonitors()
        // The arrow flips the moment you close, like the native one.
        catcher.setOpen(false, cover: barCapture.collapsedArrow)
        let length = spacer.length
        Task { @MainActor in
            let snap = await Task.detached { BarReader.snapshot(spacerLength: length) }.value
            guard token == self.phaseToken else { return }
            let revealed = snap.visible.filter { self.revealedKeys.contains(BarReader.key(for: $0)) }
                .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
            var xs: [String: CGFloat] = [:]
            for item in revealed { if let f = item.frame { xs[BarReader.key(for: item)] = f.minX } }
            let arrow = self.revealArrow ?? snap.spacer ?? .zero
            let rect = self.coverRectAX(arrow: arrow)
            let covered = self.cover.show(self.barCapture.backgroundPatch(for: rect), over: rect, fadeIn: 0.08)
            if covered {
                self.panel.open(entries: self.entries(for: revealed), arrow: arrow, boundary: self.boundary, barTop: self.barTop,
                                barHeight: self.barHeight(for: arrow), absoluteX: xs, animated: false)
                self.catcher.bringToFront()
            }
            // Let the cover and panel fade in over the real icons first.
            try? await Task.sleep(for: .milliseconds(covered ? 90 : 0))
            guard token == self.phaseToken else { return }
            self.spacer.setRevealed(false)
            self.panel.close(animated: covered)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard token == self.phaseToken else { return }
                self.cover.hide(fade: 0.08)
                self.catcher.setOpen(false)
                self.revealedPIDs = []
                self.revealedKeys = []
                self.revealBaseline = []
                self.phase = .hidden
                self.scheduleRefresh()
            }
        }
    }

    /// `pressMode ax`: press from the panel without revealing; the panel stays
    /// open and the menu opens at the item's parked spot. Clicking the open
    /// item again closes its menu; clicking another switches to it.
    private func pickInPanel(_ item: MenuBarItem) {
        if let tracker, BarReader.key(for: tracker.item) == BarReader.key(for: item) {
            tracker.dismiss()
            endTracking()
            return
        }
        let previous = tracker
        previous?.dismiss()
        endTracking()
        // Give a dismissed NSMenu a moment to stop tracking before the next press.
        let delay = previous?.isTrackingMenu == true ? 0.12 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.panel.isOpen else { return }
            let tracker = MenuTracker(item: item)
            self.tracker = tracker
            self.panel.setPressed(item)
            let result = AX.press(item.pressElement)
            Log.write("Open \(item.displayName): AXPress → \(result.rawValue)")
            self.trackTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackTick() }
            }
        }
    }

    private func trackTick() {
        guard let tracker else { return }
        switch tracker.poll() {
        case .waiting:
            break
        case .closed:
            Log.write("Menu of \(tracker.item.displayName) closed; panel stays open")
            endTracking()
        case .open:
            if UserDefaults.standard.object(forKey: "realignPopovers") as? Bool ?? true,
               let anchor = panel.itemFrames.first(where: { BarReader.key(for: $0.item) == BarReader.key(for: tracker.item) })?.frame {
                let barBottom = BarReader.primaryHeight - panel.frame.minY
                tracker.realign(under: anchor, barBottomAX: barBottom)
            }
        }
    }

    private func endTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        tracker = nil
        panel.setPressed(nil)
    }

    /// Old alternative (`pressMode reveal`): reveal without the panel cover,
    /// press, and hide again on the next click.
    private func pressRevealed(_ item: MenuBarItem) {
        spacer.item.length = HidingSpacer.editWidth
        restoreAfterPress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let result = AX.press(item.pressElement)
            Log.write("Open \(item.displayName) revealed: AXPress → \(result.rawValue) frame=\(String(describing: MenuBarEnumerator.frame(of: item.element)))")
            self?.waitForClickThenRestore()
        }
    }

    private func waitForClickThenRestore() {
        var monitor: Any?
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.restoreAfterPress = false; self?.refresh() }
            }
        }
    }

    // MARK: Editing the layout

    func beginEditing() {
        closePanel(animated: false)
        if spacer.isRevealed { conceal() }
        spacer.setEditing(true)
        catcher.cover(arrow: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let window = self.spacer.item.button?.window else { return }
            self.editHint.show(below: window.frame)
        }
    }

    @objc private func spacerClicked() {
        if spacer.isEditing { finishEditing() } else if spacer.isRevealed { conceal() }
    }

    func finishEditing() {
        guard spacer.isEditing else { return }
        editHint.hide()
        UserDefaults.standard.set(true, forKey: Self.didEditLayoutKey)
        // Everything is on the bar right now: remember order and images.
        captureThenHide()
    }

    /// Photographs every item while all are on the bar, then hides again.
    private func captureThenHide() {
        let length = spacer.length
        Task { @MainActor in
            let snap = await Task.detached(priority: .userInitiated) { BarReader.snapshot(spacerLength: length) }.value
            let screen = BarReader.screen(for: snap.spacer ?? snap.arrow ?? snap.visible.first?.frame, in: BarReader.screens())
            // Only what is really drawn: items still in overflow report the
            // arrow's position, and cropping there would capture the arrow.
            self.images.rememberOrder(snap.visible + snap.hidden)
            await self.images.capture(snap.visible, on: screen)
            self.spacer.setEditing(false)
            self.spacer.item.length = 300
            self.refresh()
        }
    }

    // MARK: Menu

    private func showMenu(at point: NSPoint) {
        closePanel(animated: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit Layout…", action: #selector(menuEdit), keyEquivalent: "").target = self
        let capture = menu.addItem(withTitle: "Refresh Item Images", action: #selector(menuCapture), keyEquivalent: "")
        capture.target = self
        capture.isEnabled = ItemImageCache.canCapture
        menu.addItem(.separator())
        menu.addItem(withTitle: "Permissions…", action: #selector(menuPermissions), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Diagnostics…", action: #selector(menuDiagnostics), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MenuShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func menuEdit() { beginEditing() }
    @objc private func menuPermissions() { openPermissions?() }
    @objc private func menuDiagnostics() { openDiagnostics?() }

    /// Briefly lets everything back onto the bar to photograph it.
    @objc private func menuCapture() {
        spacer.setEditing(true)
        catcher.cover(arrow: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.captureThenHide()
        }
    }

    // MARK: Debug (`--debug` only)

    /// Commands from scripts/spike.swift ("dev.menushelf.spike"): snap, open,
    /// close, press <n>, width <w> (freezes auto width), auto, edit, done.
    /// Only with --debug: any local process could send these.
    private func installDebugCommands() {
        Log.write("Debug commands enabled")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.menushelf.spike"), object: nil, queue: .main
        ) { [weak self] note in
            let parts = (note.object as? String ?? "").split(separator: " ").map(String.init)
            MainActor.assumeIsolated { self?.debug(parts) }
        }
    }

    private func debug(_ parts: [String]) {
        Log.write("DEBUG command: \(parts.joined(separator: " "))")
        switch parts.first {
        case "snap":
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logSnapshot() }
        case "open": openPanel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.logSnapshot() }
        case "close": closePanel()
        case "press":
            let hidden = sortedHidden()
            if let n = parts.dropFirst().first.flatMap(Int.init), hidden.indices.contains(n) { pick(hidden[n]) }
        case "width":
            if let w = parts.dropFirst().first.flatMap(Double.init) { widthFrozen = true; spacer.item.length = CGFloat(w) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.logSnapshot() }
        case "auto": widthFrozen = false; refresh()
        case "barwindows": Task { await ItemImageCache.debugCaptureBarWindows() }
        case "shot": Task { await BarCapture.debugShot(name: parts.dropFirst().first ?? "shot") }
        case "film":
            // film <name> <count> <ms>: a burst of bar screenshots.
            let name = parts.count > 1 ? parts[1] : "film"
            let count = parts.count > 2 ? Int(parts[2]) ?? 10 : 10
            let ms = parts.count > 3 ? Int(parts[3]) ?? 80 : 80
            Task {
                for i in 0..<count {
                    await BarCapture.debugShot(name: String(format: "%@-%02d", name, i))
                    try? await Task.sleep(for: .milliseconds(ms))
                }
            }
        case "edit": beginEditing()
        case "done": finishEditing()
        default: break
        }
    }

    private func logSnapshot() {
        func r(_ f: CGRect?) -> String { f.map { "\(Int($0.minX))+\(Int($0.width))@\(Int($0.minY))" } ?? "nil" }
        var lines = ["DEBUG snap screen=\(barScreen.map { "\($0.displayID) \($0.frame) notch=\($0.notchRight.map { "\(Int($0))" } ?? "none")" } ?? "nil") boundary=\(Int(boundary)) len=\(Int(spacer.length)) spacer=\(r(snapshot.spacer)) arrow=\(r(snapshot.arrow)) catcher=\(catcher.isShown ? "\(catcher.frame)" : "hidden") panelOpen=\(panel.isOpen) panel=\(panel.frame)"]
        for (i, item) in sortedHidden().enumerated() {
            lines.append("  hidden[\(i)] \(r(item.frame)) \(item.displayName) image=\(images.hasImage(for: BarReader.key(for: item)))")
        }
        for item in snapshot.visible { lines.append("  visible \(r(item.frame)) \(item.displayName)") }
        Log.write(lines.joined(separator: "\n"))
    }

    func prepareForTermination() {
        // Leave the bar uncluttered for next launch; the spacer's position is
        // kept by macOS under its autosave name.
        closePanel(animated: false)
        if spacer.isRevealed { spacer.setRevealed(false) }
    }
}

/// Small floating hint under the divider while editing.
@MainActor
final class EditHint {
    private var panel: NSPanel?
    var onDone: (() -> Void)?

    func show(below anchor: NSRect) {
        let label = NSTextField(wrappingLabelWithString: "⌘-drag icons to the left of this divider to hide them, to the right to keep them visible.")
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 240
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        let stack = NSStackView(views: [label, done])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: anchor.midX - size.width + 20, y: anchor.minY - size.height - 6, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.contentView = effect
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func doneClicked() { onDone?() }
}
