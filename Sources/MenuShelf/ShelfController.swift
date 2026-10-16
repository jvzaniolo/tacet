import AppKit

/// MenuShelf: hides apps' menu bar items with MenuBarAgent's own restriction,
/// so macOS animates the real icons (NOTES §11).
///
///     notch | [hidden apps …] | »  [visible items …]  Clock
///                             ^ ^
///                       divider chevron (ours; divider only while editing)
///
/// - Concealed: an assertion allows every running app except the hidden set.
/// - Revealed: an assertion allows everything (swapped in without a gap).
///   The real icons are on the bar, so menus and switching are native.
/// - Editing: no assertion, divider shown; ⌘-drag icons across it. On Done the
///   hidden set = apps whose items are all left of the divider.
@MainActor
final class ShelfController {
    enum State { case concealed, revealed, editing }

    private let restriction = Restriction()
    private let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private(set) var state: State = .concealed
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// Windows the hidden apps had on screen when revealed; newer ones are
    /// their menus or popovers.
    private var revealBaseline: Set<CGWindowID> = []

    var openPermissions: (() -> Void)?

    private static let hiddenKey = "hiddenBundleIDs.v2"

    var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.hiddenKey) }
    }

    func start() {
        // Created right-to-left: the chevron first, so the divider sits left of it.
        chevron.autosaveName = "MenuShelfChevron"
        divider.autosaveName = "MenuShelfDivider"
        for item in [chevron, divider] {
            guard let button = item.button else { continue }
            button.target = self
            // Act on mouse-down for an instant response. The light capsule
            // shown while the button is held is macOS's normal press look
            // and goes away on release.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            // No pressed capsule: the native overflow arrow has none.
            (button.cell as? NSButtonCell)?.highlightsBy = []
            (button.cell as? NSButtonCell)?.showsStateBy = []
        }
        chevron.button?.action = #selector(chevronClicked)
        divider.button?.action = #selector(dividerClicked)
        divider.button?.toolTip = "MenuShelf divider — ⌘-drag icons to its left to hide them, then click here"

        restriction.onApplied = { mode, ms in
            Log.write("Applied \(Restriction.describe(mode)) after \(Int(ms * 1000)) ms")
        }
        if CommandLine.arguments.contains("--debug") { DebugCommands.install(shelf: self) }

        guard Restriction.isAvailable else {
            Log.write("MenuBarClientCore assertion API not found; MenuShelf can't hide on this macOS")
            render()
            return
        }
        if hidden.isEmpty && !UserDefaults.standard.bool(forKey: "didEditLayoutOnce") {
            beginEditing()
        } else {
            conceal()
        }
    }

    // MARK: States

    /// Our items and the assertion change in the same run-loop turn, so
    /// MenuBarAgent lays the bar out in one pass.
    func conceal() {
        state = .concealed
        removeMonitors()
        render()
        restriction.set(hidden.isEmpty ? .off : .hiding(hidden))
    }

    func reveal() {
        state = .revealed
        render()
        revealBaseline = Set(hiddenPIDs().flatMap { MenuTracker.windows(of: $0).map(\.id) })
        restriction.set(.showingAll)
        installMonitors()
    }

    func beginEditing() {
        state = .editing
        removeMonitors()
        render()
        restriction.set(.off)
    }

    /// Done: the apps whose items are all left of the divider become hidden.
    func finishEditing() {
        guard state == .editing else { return }
        guard AX.isTrusted(prompt: false) else {
            Log.write("Done: Accessibility is off; can't read the layout")
            openPermissions?()
            return
        }
        UserDefaults.standard.set(true, forKey: "didEditLayoutOnce")
        Task { @MainActor in
            let scan = await Task.detached { MenuBarEnumerator.enumerate(includeOwn: true) }.value
            let own = ProcessInfo.processInfo.processIdentifier
            let ownItems = scan.apps.filter { $0.pid == own }.flatMap(\.items).compactMap(\.frame)
            // Our divider is the leftmost of our two items.
            guard let dividerX = ownItems.map(\.minX).min() else {
                Log.write("Done: couldn't find the divider in AX")
                return
            }
            // An item is left of the divider when its centre is: AX frames
            // include padding, and some (Claude's) are much wider than the
            // icon, so their right edge can overlap the divider.
            var newHidden = Set<String>()
            var decisions: [String] = []
            for app in scan.apps where app.pid != own {
                guard let bundleID = app.bundleID, !bundleID.hasPrefix("com.apple.") else { continue }
                let mids = app.items.compactMap { $0.frame?.midX }
                let left = mids.filter { $0 < dividerX }.count
                let hide = !mids.isEmpty && left == mids.count
                if hide { newHidden.insert(bundleID) }
                decisions.append("\(bundleID) \(left)/\(mids.count) left → \(hide ? "hide" : "keep")")
            }
            Log.write("Done: divider at x \(Int(dividerX)); " + decisions.joined(separator: "; "))
            hidden = newHidden
            Log.write("Done: hidden = \(newHidden.sorted())")
            conceal()
        }
    }

    // MARK: Our items

    private func render() {
        let open = state != .concealed
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let name = open ? "chevron.forward.2" : "chevron.backward.2"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: open ? "Hide Menu Bar Items" : "Show Hidden Menu Bar Items")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        chevron.button?.image = image
        chevron.button?.toolTip = open ? "Hide Menu Bar Items" : "Show Hidden Menu Bar Items"
        chevron.isVisible = true

        if state == .editing {
            let bar = NSImage(size: NSSize(width: 6, height: 18), flipped: false) { rect in
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 2, height: 16), xRadius: 1, yRadius: 1).fill()
                return true
            }
            bar.isTemplate = true
            divider.button?.image = bar
            divider.isVisible = true
        } else {
            divider.isVisible = false
        }
    }

    /// The native overflow arrow shows no pressed capsule; on macOS 27
    /// `highlightsBy = []` alone doesn't stop it, so also clear the
    /// highlight as soon as the click arrives and again after the layout pass.
    private func clearHighlight(_ item: NSStatusItem) {
        item.button?.highlight(false)
        item.button?.isHighlighted = false
        DispatchQueue.main.async { item.button?.highlight(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { item.button?.highlight(false) }
    }

    @objc private func chevronClicked() {
        clearHighlight(chevron)
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        switch state {
        case .concealed: reveal()
        case .revealed: conceal()
        case .editing: finishEditing()
        }
    }

    @objc private func dividerClicked() {
        clearHighlight(divider)
        if state == .editing { finishEditing() }
    }

    private func showMenu() {
        let menu = NSMenu()
        if state == .editing {
            menu.addItem(withTitle: "Done Editing", action: #selector(menuDone), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Edit Layout…", action: #selector(menuEdit), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Permissions…", action: #selector(menuPermissions), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit MenuShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        chevron.menu = menu
        chevron.button?.performClick(nil)
        chevron.menu = nil
    }

    @objc private func menuEdit() { beginEditing() }
    @objc private func menuDone() { finishEditing() }
    @objc private func menuPermissions() { openPermissions?() }

    // MARK: Close rules (native overflow, NOTES §8)

    /// While revealed: a click outside the menu bar and outside any menu or
    /// popover of the revealed apps conceals; so does Esc with no menu open.
    /// Clicks on the bar itself (other items) keep it open. No timer.
    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.state == .revealed else { return }
                if Self.isInMenuBar(location) || self.isInMenu(location) { return }
                self.conceal()
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, self.state == .revealed, !self.isAnyMenuOpen() else { return }
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

    private func hiddenPIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map(hidden.contains) ?? false }.map(\.processIdentifier)
    }

    /// Menus (any app) and windows the revealed apps opened since revealing.
    private func menuWindows() -> [MenuTracker.OwnerWindow] {
        let menus = MenuTracker.allWindows().filter(\.isMenu)
        let popovers = hiddenPIDs().flatMap { MenuTracker.windows(of: $0) }.filter { !revealBaseline.contains($0.id) }
        return menus + popovers
    }

    private func isInMenu(_ point: NSPoint) -> Bool {
        let ax = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        return menuWindows().contains { $0.bounds.insetBy(dx: -2, dy: -2).contains(ax) }
    }

    private func isAnyMenuOpen() -> Bool { !menuWindows().isEmpty }

    func prepareForTermination() {
        removeMonitors()
        // Quitting ends our assertions, which shows everything again.
        restriction.releaseAll()
    }

    // MARK: Debug access

    var restrictionForDebug: Restriction { restriction }
    var chevronForDebug: NSStatusItem { chevron }
}
