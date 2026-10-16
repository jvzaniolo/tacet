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
    /// Keep Open: stays revealed until the arrow is clicked.
    private var pinned = false
    /// Windows the hidden apps had on screen when revealed; newer ones are
    /// their menus or popovers.
    private var revealBaseline: Set<CGWindowID> = []

    var openSettings: (() -> Void)?
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
            // Mouse-down, like the native arrow. The light capsule shown
            // while the button is held is macOS's press look.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            (button.cell as? NSButtonCell)?.highlightsBy = []
            (button.cell as? NSButtonCell)?.showsStateBy = []
        }
        render()
        conceal()
    }

    // MARK: States

    func conceal() {
        pinned = false
        removeMonitors()
        model.conceal()
        render()
    }

    func reveal(pinned: Bool = false) {
        self.pinned = pinned
        let pids = hiddenPIDs()
        revealBaseline = Set(MenuTracker.allWindows().filter { pids.contains($0.pid) }.map(\.id))
        model.reveal()
        render()
        if pinned { removeMonitors() } else { installMonitors() }
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
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        if model.expired {
            showExpired?()
            return
        }
        // Nothing to show yet (no access, or no hidden apps): open Settings.
        guard model.access == .granted, model.hasHiddenApps || model.revealed else {
            openSettings?()
            return
        }
        if model.revealed { conceal() } else { reveal() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        let showAll = menu.addItem(withTitle: String(localized: "Keep Open"), action: #selector(menuShowAll), keyEquivalent: "")
        showAll.target = self
        showAll.state = pinned ? .on : .off
        showAll.isEnabled = !model.expired
        if BuildInfo.feedbackURL != nil {
            menu.addItem(withTitle: String(localized: "Send Feedback…"), action: #selector(menuFeedback), keyEquivalent: "").target = self
        }
        if BuildInfo.isBeta {
            menu.addItem(.separator())
            let beta = menu.addItem(withTitle: String(localized: "Beta \(BuildInfo.shortVersion) · ends \(BuildInfo.expiryText)"), action: nil, keyEquivalent: "")
            beta.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Tacet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        arrow.menu = menu
        arrow.button?.performClick(nil)
        arrow.menu = nil
    }

    @objc private func menuSettings() { openSettings?() }
    @objc private func menuFeedback() { BuildInfo.feedbackURL.map { _ = NSWorkspace.shared.open($0) } }
    @objc private func menuShowAll() { if pinned { conceal() } else { reveal(pinned: true) } }

    // MARK: Close rules (like the native overflow arrow)

    /// While revealed: a click outside the menu bar and outside any menu or
    /// popover of the revealed apps conceals; so does Esc with no menu open.
    /// Clicks on the bar itself (other items) keep it open. No timer.
    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.model.revealed, !self.pinned else { return }
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
                guard let self, self.model.revealed, !self.pinned, !self.isAnyMenuOpen() else { return }
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

    private func hiddenPIDs() -> Set<pid_t> {
        let hidden = model.hidden
        return Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(hidden.contains) ?? false }
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

    /// Quit: every app Tacet switched off is turned back on.
    func prepareForTermination() {
        removeMonitors()
        let ok = model.restoreAll()
        Log.write("Quit: restored hidden apps (\(ok ? "ok" : "failed"))")
    }
}
