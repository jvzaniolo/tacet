import AppKit
import ApplicationServices

/// Spike: can a wide spacer status item force macOS 27's native overflow
/// arrow to appear and take the items left of it?
///
/// Driven from the shell (see scripts/spike.swift) by the distributed
/// notification "dev.menushelf.spike", whose object is a command:
///   spacer <width> [plain|image|divider]   create/resize the spacer
///   remove                                   remove the spacer
///   probe                                    log the bar layout
///   press                                    AXPress the overflow arrow, probe after
///   watch on|off                             log arrow state changes + AX notifications
/// Everything is logged to ~/Library/Logs/MenuShelf.log with a "SPIKE" prefix.
@MainActor
final class SpikeController {
    var spacer: NSStatusItem?
    var autoTimer: Timer?
    var lastApply = Date.distantPast
    var pendingTarget: CGFloat?
    private var watchTimer: Timer?
    private var lastArrowState: String?
    private var lastArrowChange = Date()
    private var observer: AXObserver?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.menushelf.spike"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(command) }
        }
    }

    func log(_ s: String) { Log.write("SPIKE \(s)") }

    private func handle(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        log("command: \(command)")
        switch parts.first {
        case "spacer":
            let width = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 0) : 300
            setSpacer(width: width, style: parts.count > 2 ? parts[2] : "image")
            probe(after: 0.8)
        case "remove":
            if let spacer { NSStatusBar.system.removeStatusItem(spacer) }
            spacer = nil
            probe(after: 0.8)
        case "probe":
            probe(after: 0)
        case "press":
            pressArrow()
        case "sweep":
            let nums = parts.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
            if nums.count == 3 { sweep(from: nums[0], to: nums[1], step: nums[2]) }
        case "geo":
            log(describeGeometry())
        case "auto":
            setAuto(parts.count > 1 && parts[1] == "on")
        case "watch":
            setWatching(parts.count > 1 && parts[1] == "on")
        default:
            log("unknown command")
        }
    }

    // MARK: Spacer

    private func setSpacer(width: CGFloat, style: String) {
        let item = spacer ?? NSStatusBar.system.statusItem(withLength: width)
        item.autosaveName = "MenuShelfSpacer"
        item.length = width
        if let button = item.button {
            switch style {
            case "plain":
                button.image = nil
                button.title = ""
            case "divider":
                button.image = Self.dividerImage(width: width)
                button.imageScaling = .scaleNone
            default:
                // Transparent content: Thaw's notes say an empty button may
                // composite as nothing on macOS 27, so give it real pixels.
                button.image = Self.clearImage(width: width)
                button.imageScaling = .scaleNone
            }
        }
        spacer = item
        log("spacer length=\(width) style=\(style) isVisible=\(item.isVisible) buttonWindow=\(item.button?.window.map { "\($0.frame)" } ?? "nil")")
    }

    private static func clearImage(width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: max(width, 1), height: 22), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.01).setFill()
            rect.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func dividerImage(width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: max(width, 1), height: 22), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.01).setFill()
            rect.fill()
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            NSRect(x: rect.maxX - 2, y: 3, width: 1, height: 16).fill()
            return true
        }
        return image
    }

    // MARK: Probe

    private func probe(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.log(Self.describeBar())
        }
    }

    static func describeBar() -> String {
        let scan = MenuBarEnumerator.enumerate(includeOwn: true)
        var lines: [String] = []
        for screen in NSScreen.screens {
            lines.append("screen \(screen.localizedName) frame=\(screen.frame) safeTop=\(screen.safeAreaInsets.top) auxLeft=\(screen.auxiliaryTopLeftArea.map { "\($0)" } ?? "nil") auxRight=\(screen.auxiliaryTopRightArea.map { "\($0)" } ?? "nil")")
        }
        lines.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        let arrowX = scan.overflowButton?.minX
        if let arrow = scan.overflowElement {
            lines.append("arrow frame=\(scan.overflowButton.map { "\($0)" } ?? "nil") \(arrowState(arrow))")
        } else {
            lines.append("arrow: none")
        }
        let items = scan.apps.flatMap { app in app.items.map { (app, $0) } }
            .sorted { ($0.1.frame?.minX ?? -9999) < ($1.1.frame?.minX ?? -9999) }
        for (app, item) in items {
            let f = item.frame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width))" } ?? "no frame"
            let side: String
            if let x = item.frame?.minX, let arrowX { side = x < arrowX ? "LEFT-of-arrow" : "right" } else { side = "-" }
            lines.append("  \(f)  \(side)  \(app.name): \(item.displayName)\(item.identifier.map { " [\($0)]" } ?? "")")
        }
        lines.append(drawnBar())
        return lines.joined(separator: "\n")
    }

    /// The arrow's label says whether the overflow is expanded.
    static func arrowState(_ arrow: AXUIElement) -> String {
        let desc = AX.string(arrow, kAXDescriptionAttribute) ?? AX.string(arrow, kAXTitleAttribute) ?? "?"
        let expanded = AX.attribute(arrow, kAXExpandedAttribute).map { "\($0)" } ?? "n/a"
        return "label=\"\(desc)\" AXExpanded=\(expanded) actions=\(AX.actionNames(arrow).map { $0.components(separatedBy: "\n")[0] })"
    }

    /// MenuBarAgent's first AX window has one child per item actually drawn.
    static func drawnBar() -> String {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return "drawn: no agent" }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let windows = (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var out = ["drawn: \(windows.count) agent windows"]
        for (i, window) in windows.prefix(3).enumerated() {
            let kids = AX.children(window)
            let frames = kids.compactMap { MenuBarEnumerator.frame(of: $0) }.map { "\(Int($0.minX))+\(Int($0.width))" }
            out.append("  window[\(i)] frame=\(MenuBarEnumerator.frame(of: window).map { "\($0)" } ?? "nil") children=\(kids.count) \(frames)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Press & watch

    private func pressArrow() {
        let scan = MenuBarEnumerator.enumerate(includeOwn: true)
        guard let arrow = scan.overflowElement else {
            log("press: no arrow")
            return
        }
        log("press: before \(Self.arrowState(arrow))")
        let error = AX.press(arrow)
        log("press: AXPress → \(error.rawValue)")
        probe(after: 0.4)
        probe(after: 1.5)
    }

    private func setWatching(_ on: Bool) {
        watchTimer?.invalidate()
        watchTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        guard on else { log("watch off"); return }

        // Poll the arrow's label: cheap and shows open/close timing.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollArrow() }
        }
        // And listen for whatever AX notifications MenuBarAgent sends.
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
            var obs: AXObserver?
            let callback: AXObserverCallback = { _, element, name, _ in
                let role = AX.string(element, kAXRoleAttribute) ?? "?"
                let desc = AX.string(element, kAXDescriptionAttribute) ?? ""
                Log.write("SPIKE ax-notification \(name) on \(role) \"\(desc)\"")
            }
            if AXObserverCreate(agent.processIdentifier, callback, &obs) == .success, let obs {
                let app = AXUIElementCreateApplication(agent.processIdentifier)
                let names = [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXValueChangedNotification,
                             kAXLayoutChangedNotification, kAXMovedNotification, kAXResizedNotification,
                             kAXTitleChangedNotification, kAXWindowCreatedNotification, kAXMenuOpenedNotification,
                             kAXMenuClosedNotification, "AXExpandedChanged", kAXFocusedUIElementChangedNotification]
                var registered: [String] = []
                for name in names where AXObserverAddNotification(obs, app, name as CFString, nil) == .success {
                    registered.append(name)
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
                observer = obs
                log("watch on; AX notifications registered: \(registered)")
            }
        }
    }

    private func pollArrow() {
        let scan = MenuBarEnumerator.enumerate(includeOwn: true)
        let state = scan.overflowElement.map(Self.arrowState) ?? "no arrow"
        guard state != lastArrowState else { return }
        let held = Date().timeIntervalSince(lastArrowChange)
        log(String(format: "arrow changed after %.1fs: %@ frame=%@", held, state, scan.overflowButton.map { "\($0)" } ?? "nil"))
        lastArrowState = state
        lastArrowChange = Date()
    }
}
