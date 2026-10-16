import AppKit
import ApplicationServices

/// Reads the live menu bar through Accessibility: macOS's overflow arrow, our
/// spacer, and the items currently in the overflow (the "hidden" ones).
/// AX frames are in global top-left coordinates; `cocoaRect` converts.
enum BarReader {
    struct Snapshot {
        var arrow: CGRect?              // AX coords
        var spacer: CGRect?             // AX coords
        var hidden: [MenuBarItem]       // left of the arrow, our own items excluded
        var visible: [MenuBarItem]
    }

    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    static func cocoaRect(_ ax: CGRect) -> CGRect {
        CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }

    /// Full scan. Blocking (tens of ms); call off the main thread.
    static func snapshot(spacerLength: CGFloat) -> Snapshot {
        let scan = MenuBarEnumerator.enumerate(includeOwn: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = scan.apps.filter { $0.pid == ownPID }.flatMap(\.items)
        // The spacer is our item whose width matches its length (AX adds ~2 pt).
        let spacer = own.compactMap(\.frame).min { abs($0.width - spacerLength - 2) < abs($1.width - spacerLength - 2) }
        let others = scan.apps.filter { $0.pid != ownPID }.flatMap(\.items)
        let arrow = scan.overflowButton
        var hidden: [MenuBarItem] = []
        var visible: [MenuBarItem] = []
        for item in others {
            if let arrow, let f = item.frame, f.minX < arrow.minX { hidden.append(item) } else { visible.append(item) }
        }
        return Snapshot(arrow: arrow, spacer: spacer, hidden: hidden, visible: visible)
    }

    /// Our spacer's own AX frame only (cheap: one process).
    static func ownSpacerFrame(spacerLength: CGFloat) -> CGRect? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let extras = AX.element(app, kAXExtrasMenuBarAttribute) else { return nil }
        return AX.children(extras).compactMap { MenuBarEnumerator.frame(of: $0) }
            .min { abs($0.width - spacerLength - 2) < abs($1.width - spacerLength - 2) }
    }

    /// MenuBarAgent's overflow arrow only (cheap: one process).
    static func arrowFrame() -> CGRect? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarEnumerator.menuBarAgentBundleID).first else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let extras = AX.element(app, kAXExtrasMenuBarAttribute) else { return nil }
        if let button = AX.element(extras, "AXOverflowButton") { return MenuBarEnumerator.frame(of: button) }
        return AX.children(extras).first { AX.string($0, kAXRoleAttribute) == kAXButtonRole }
            .flatMap { MenuBarEnumerator.frame(of: $0) }
    }

    /// Plain snapshot of a screen, safe to pass to background work.
    struct ScreenInfo: Sendable {
        let frame: CGRect          // Cocoa global
        let notchRight: CGFloat?   // auxiliaryTopRightArea.minX
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        /// Top edge in AX (top-left) global coordinates.
        var axTop: CGFloat { BarReader.primaryHeightValue - frame.maxY }
        func containsAX(_ rect: CGRect) -> Bool {
            let mid = CGPoint(x: rect.midX, y: BarReader.primaryHeightValue - rect.midY)
            return frame.insetBy(dx: -1, dy: -1).contains(mid)
        }
    }

    nonisolated(unsafe) static var primaryHeightValue: CGFloat = 0

    @MainActor
    static func screens() -> [ScreenInfo] {
        primaryHeightValue = primaryHeight
        return NSScreen.screens.map {
            ScreenInfo(frame: $0.frame, notchRight: $0.auxiliaryTopRightArea?.minX, displayID: $0.displayID, scale: $0.backingScaleFactor)
        }
    }

    /// The screen whose menu bar holds `rect` (AX coords).
    static func screen(for rect: CGRect?, in screens: [ScreenInfo]) -> ScreenInfo? {
        guard let rect else { return screens.first { $0.frame.origin == .zero } ?? screens.first }
        return screens.first { $0.containsAX(rect) } ?? screens.first { $0.frame.origin == .zero }
    }

    /// Where the trailing status area starts on `screen`: the notch's right
    /// edge, or the end of the frontmost app's menus on a display without a
    /// notch. Blocking AX on non-notch displays.
    static func leadingBoundary(on screen: ScreenInfo?) -> CGFloat {
        if let notch = screen?.notchRight { return notch }
        guard let front = NSWorkspace.shared.frontmostApplication else { return screen?.frame.minX ?? 0 }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return screen?.frame.minX ?? 0 }
        let frames = AX.children(bar).compactMap { MenuBarEnumerator.frame(of: $0) }
            .filter { f in screen.map { $0.containsAX(f) } ?? true }
        return frames.map(\.maxX).max() ?? (screen?.frame.minX ?? 0)
    }

    /// Stable key for caching an item's image and order.
    static func key(for item: MenuBarItem) -> String {
        let owner = NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier ?? "pid\(item.pid)"
        // Text items change their title ("13m left"); ignore digits so the
        // key stays stable.
        let label = item.identifier ?? (item.title ?? item.itemDescription ?? item.help ?? "?")
            .filter { !$0.isNumber }
        return "\(owner)|\(label)"
    }
}
