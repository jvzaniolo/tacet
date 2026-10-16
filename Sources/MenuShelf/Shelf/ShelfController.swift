import AppKit

/// MenuShelf v1: hide with the spacer, reveal in our own panel, one arrow.
///
/// - The spacer pushes everything left of it into macOS's overflow.
/// - macOS then shows its overflow arrow at the spacer's right end. That arrow
///   is our only arrow: ArrowCatcher sits on top of it and takes its clicks,
///   so macOS's own expansion never runs.
/// - Clicking opens RevealPanel with the hidden items (cached images, so it is
///   instant). Picking one presses the real item.
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
    private var restoreAfterPress = false

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
        snapshot = snap
        barScreen = screen
        self.boundary = boundary
        guard !spacer.isEditing else { catcher.cover(arrow: nil); return }
        guard !restoreAfterPress, !widthFrozen else { catcher.cover(arrow: snap.arrow); return }
        if let frame = snap.spacer, spacer.fit(spacerFrame: frame, arrow: snap.arrow, boundary: boundary) {
            scheduleRefresh()
        }
        catcher.cover(arrow: snap.arrow)
        if panel.isOpen, snap.arrow == nil { closePanel() }
    }

    // MARK: Panel

    private func togglePanel() {
        panel.isOpen ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let arrow = snapshot.arrow else { return }
        // Bar height from the arrow: it is vertically centred in the bar.
        let top = barScreen?.axTop ?? 0
        let barHeight = max(((arrow.midY - top) * 2).rounded(), 24)
        let entries = sortedHidden().map { item -> RevealPanel.Entry in
            let key = BarReader.key(for: item)
            if let image = images.image(for: key) { return .init(item: item, image: image, isCaptured: true) }
            let icon = NSRunningApplication(processIdentifier: item.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
            return .init(item: item, image: icon, isCaptured: false)
        }
        panel.open(entries: entries, arrow: arrow, boundary: boundary, barTop: top, barHeight: barHeight)
        catcher.setOpen(true)
        installMouseMonitor()
    }

    private func closePanel(animated: Bool = true) {
        panel.close(animated: animated)
        catcher.setOpen(false)
        removeMouseMonitor()
    }

    /// Hidden items in last-seen bar order (left to right).
    private func sortedHidden() -> [MenuBarItem] {
        snapshot.hidden.enumerated().sorted { a, b in
            let ka = images.order[BarReader.key(for: a.element)] ?? CGFloat(a.offset) - 10000
            let kb = images.order[BarReader.key(for: b.element)] ?? CGFloat(b.offset) - 10000
            return ka < kb
        }.map(\.element)
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.panel.isOpen else { return }
                if self.panel.frame.contains(location) || self.catcher.frame.contains(location) { return }
                self.closePanel()
            }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Opening an item

    private func pick(_ item: MenuBarItem) {
        // The native overflow closes when one of its items opens a menu.
        closePanel(animated: false)
        let mode = UserDefaults.standard.string(forKey: "pressMode") ?? "ax"
        if mode == "reveal" {
            pressRevealed(item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let result = AX.press(item.pressElement)
                Log.write("Open \(item.displayName): AXPress → \(result.rawValue)")
            }
        }
    }

    /// Alternative: let the item back onto the bar, press it there so its
    /// menu opens under it, and hide again on the next click.
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
        spacer.setEditing(true)
        catcher.cover(arrow: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let window = self.spacer.item.button?.window else { return }
            self.editHint.show(below: window.frame)
        }
    }

    @objc private func spacerClicked() {
        if spacer.isEditing { finishEditing() }
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
            await self.images.capture(snap.visible, on: screen)
            self.images.rememberOrder(snap.hidden)
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
