import AppKit

/// Tacet's one status item, an arrow like the native overflow one:
/// « when hidden apps are hidden, » while they're shown (NOTES §13).
///
/// Clicking it flips the "Allow in the Menu Bar" switches of the hidden apps
/// in one write; macOS hides, shows and animates the real icons.
@MainActor
final class ShelfController {
    let model: ShelfModel
    private let arrow = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// Windows the hidden apps had on screen when revealed; newer ones are
    /// their menus or popovers.
    private var revealBaseline: Set<CGWindowID> = []
    private var autoHideTimer: Timer?
    /// When the apps hide again on their own; nil while the countdown waits
    /// (the pointer is on the menu bar, or a menu is open).
    private var autoHideDeadline: Date?
    /// Fixed, no setting: 5 s felt rushed.
    private static let autoHideDelay: TimeInterval = 10

    var openSettings: (() -> Void)?
    /// The global shortcut, shown next to the menu's show/hide item while on.
    var hotkey: Hotkey?
    /// Beta build past its expiry: the arrow shows the "beta has ended" window.
    var showExpired: (() -> Void)?

    init(model: ShelfModel) {
        self.model = model
    }

    func start() {
        arrow.autosaveName = "TacetArrow"
        if let button = arrow.button {
            button.target = self
            button.action = #selector(arrowClicked)
            // Left click on mouse-down, like the native arrow (the light
            // capsule shown while held is macOS's press look). The right-click
            // menu on mouse-up: opened from inside a mouse-down, the button
            // keeps waiting for a mouse-up the menu already consumed, and in
            // that tracking loop AppKit never processes the app's activation,
            // so Settings opened from the menu stayed unfocused (NOTES §18).
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            (button.cell as? NSButtonCell)?.highlightsBy = []
            (button.cell as? NSButtonCell)?.showsStateBy = []
        }
        render()
        conceal()
    }

    // MARK: States

    func conceal() {
        removeMonitors()
        stopAutoHide()
        model.conceal()
        render()
    }

    /// `all`: ⌥-click, the always-hidden apps are shown too.
    func reveal(all: Bool = false) {
        let pids = pids(for: all ? model.hidden.union(model.alwaysHidden) : model.hidden)
        revealBaseline = Set(MenuTracker.allWindows().filter { pids.contains($0.pid) }.map(\.id))
        model.reveal(all: all)
        render()
        installMonitors()
        startAutoHide()
    }

    private func render() {
        let open = model.revealed
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let name = open ? "chevron.forward.2" : "chevron.backward.2"
        // Apple's own labels for its overflow arrow (MenuBarAgent).
        let title = open ? String(localized: "Hide Menu Bar Items") : String(localized: "Show Hidden Menu Bar Items")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: title)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        arrow.button?.image = image
        arrow.button?.toolTip = title
    }

    /// The native arrow shows no pressed capsule; `highlightsBy = []` alone
    /// doesn't stop it on macOS 27, so clear it now and after the layout pass.
    private func clearHighlight() {
        arrow.button?.highlight(false)
        DispatchQueue.main.async { self.arrow.button?.highlight(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.arrow.button?.highlight(false) }
    }

    @objc private func arrowClicked() {
        clearHighlight()
        // On macOS 27 the click reaches the status item without its modifier
        // flags (always 0); NSEvent.modifierFlags, the keys held right now,
        // has them and needs no permission (NOTES §21).
        let modifiers = NSEvent.modifierFlags.union(NSApp.currentEvent?.modifierFlags ?? [])
        if let event = NSApp.currentEvent {
            Log.debug("Arrow: event type \(event.type.rawValue), event flags 0x\(String(event.modifierFlags.rawValue, radix: 16)), keys held 0x\(String(NSEvent.modifierFlags.rawValue, radix: 16))")
            if event.type == .rightMouseUp {
                showMenu()
                return
            }
            if modifiers.contains(.control) {
                // Control-click arrives on mouse-down: open the menu once the
                // button's tracking has ended (same reason as above).
                RunLoop.main.perform(inModes: [.default]) { [weak self] in
                    MainActor.assumeIsolated { self?.showMenu() }
                }
                return
            }
        }
        toggle(all: modifiers.contains(.option))
    }

    /// A click on the arrow, or the global shortcut. `all` (⌥-click) also
    /// shows the always-hidden apps; ⌥-click while only the hidden ones are
    /// shown adds them.
    func toggle(all: Bool = false) {
        if model.expired {
            showExpired?()
            return
        }
        // Nothing to show yet (no access, or no hidden apps): open Settings.
        let hasApps = model.hasHiddenApps || (all && model.hasAlwaysHiddenApps)
        guard model.access == .granted, hasApps || model.revealed else {
            openSettings?()
            return
        }
        if model.revealed && !(all && !model.revealedAll) { conceal() } else {
            if all { Log.write("Reveal: hidden and always-hidden apps (⌥)") }
            reveal(all: all)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if let hotkey, let shortcut = hotkey.shortcut, hotkey.isActive, model.access == .granted, model.hasHiddenApps || model.revealed, !model.expired {
            // Shorter than the arrow's labels, so the menu stays narrow; the
            // item exists to show the shortcut.
            let title = model.revealed ? String(localized: "Hide Items") : String(localized: "Show Hidden Items")
            let item = menu.addItem(withTitle: title, action: #selector(menuToggle), keyEquivalent: shortcut.keyEquivalent)
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = self
            // Held ⌥ turns it into "Show All Items" with the ⌥ variant,
            // as macOS menus do (an alternate item).
            if !model.revealed, model.hasAlwaysHiddenApps, let variant = hotkey.variant, !hotkey.isVariantTaken {
                let all = menu.addItem(withTitle: String(localized: "Show All Items"), action: #selector(menuToggleAll), keyEquivalent: shortcut.keyEquivalent)
                all.keyEquivalentModifierMask = variant.modifiers
                all.isAlternate = true
                all.target = self
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        if BuildInfo.feedbackURL != nil {
            menu.addItem(withTitle: String(localized: "Send Feedback…"), action: #selector(menuFeedback), keyEquivalent: "").target = self
        }
        if BuildInfo.isBeta {
            menu.addItem(.separator())
            // "Beta 2 (0.1.0) · ends in 60 days"; Settings shows the date.
            let beta = menu.addItem(withTitle: BuildInfo.betaMenuText, action: nil, keyEquivalent: "")
            beta.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Tacet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        arrow.menu = menu
        arrow.button?.performClick(nil)
        arrow.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuToggleAll() { toggle(all: true) }
    @objc private func menuSettings() { openSettings?() }
    @objc private func menuFeedback() { BuildInfo.feedbackURL.map { _ = NSWorkspace.shared.open($0) } }

    // MARK: Close rules (like the native overflow arrow)

    /// While revealed: a click outside the menu bar and outside any menu or
    /// popover of the revealed apps conceals; so does Esc with no menu open.
    /// Clicks on the bar itself (other items) keep it open. It also hides
    /// again on its own (see autoHideTick).
    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.model.revealed else { return }
                if Self.isInMenuBar(location) || self.isInMenu(location) { return }
                self.conceal()
            }
        }
        // macOS delivers global key events only to apps the user trusted
        // for Accessibility. Tacet doesn't ask for it, so Esc works only
        // where it was granted anyway.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, self.model.revealed, !self.isAnyMenuOpen() else { return }
                self.conceal()
            }
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
    }

    static func isInMenuBar(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            return point.x >= screen.frame.minX && point.x <= screen.frame.maxX
                && point.y >= screen.frame.maxY - barHeight - 1 && point.y <= screen.frame.maxY
        }
    }

    /// The apps on screen because of the reveal.
    private func hiddenPIDs() -> Set<pid_t> { pids(for: model.shownApps) }

    private func pids(for ids: Set<String>) -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(ids.contains) ?? false }
            .map(\.processIdentifier))
    }

    /// Menus (any app) and windows the revealed apps opened since revealing.
    /// One window-list copy per call (review §5.1).
    private func menuWindows() -> [MenuTracker.OwnerWindow] {
        let pids = hiddenPIDs()
        return MenuTracker.allWindows().filter { window in
            window.isMenu || (pids.contains(window.pid) && !revealBaseline.contains(window.id))
        }
    }

    private func isInMenu(_ point: NSPoint) -> Bool {
        let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        return menuWindows().contains { $0.bounds.insetBy(dx: -2, dy: -2).contains(flipped) }
    }

    private func isAnyMenuOpen() -> Bool { !menuWindows().isEmpty }

    // MARK: Hiding again on their own

    /// Conceals after `autoHideDelay` with the pointer away from the menu
    /// bar and no menu open, the same way a click on the arrow does. The
    /// pointer on the bar or an open menu resets the countdown, so an icon
    /// the user is about to click never disappears. Polls the pointer (no
    /// permission needed) only while revealed.
    private func startAutoHide() {
        stopAutoHide()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoHideTick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)   // also while a menu tracks
        autoHideTimer = timer
    }

    private func stopAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        autoHideDeadline = nil
    }

    private func autoHideTick() {
        guard model.revealed else {
            stopAutoHide()
            return
        }
        // The pointer check first: it's free, the window list isn't.
        if Self.isInMenuBar(NSEvent.mouseLocation) || isMenuOrPopoverOpen() {
            autoHideDeadline = nil
            return
        }
        guard let deadline = autoHideDeadline else {
            autoHideDeadline = Date().addingTimeInterval(Self.autoHideDelay)
            return
        }
        if Date() >= deadline {
            Log.write("Hiding again after \(Int(Self.autoHideDelay)) s away from the menu bar")
            conceal()
        }
    }

    /// Menus (any app), and windows the revealed apps opened above the
    /// normal level since revealing (their popovers and panels). A regular
    /// window one of them opened, like its settings, doesn't hold it open.
    private func isMenuOrPopoverOpen() -> Bool {
        menuWindows().contains { $0.isMenu || $0.layer > Int(CGWindowLevelForKey(.normalWindow)) }
    }

    /// Quit: every app Tacet switched off is turned back on.
    func prepareForTermination() {
        removeMonitors()
        stopAutoHide()
        let ok = model.restoreAll()
        Log.write("Quit: restored hidden apps (\(ok ? "ok" : "failed"))")
    }
}
