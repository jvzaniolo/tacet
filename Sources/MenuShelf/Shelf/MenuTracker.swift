import AppKit
import ApplicationServices

/// Follows the menu or popover that a pressed item opened, using the owning
/// app's on-screen windows from CGWindowList (owner PID, level and bounds
/// need no Screen Recording). Windows that appear after the press belong to
/// the item; they disappear when its menu closes.
@MainActor
final class MenuTracker {
    struct OwnerWindow {
        let id: CGWindowID
        let layer: Int
        let bounds: CGRect   // top-left global (AX) coordinates
        var isMenu: Bool { layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    let item: MenuBarItem
    private let baseline: Set<CGWindowID>
    private let started = Date()
    private(set) var windows: [OwnerWindow] = []
    private(set) var sawMenu = false
    private var realigned: Set<CGWindowID> = []

    init(item: MenuBarItem) {
        self.item = item
        baseline = Set(Self.windows(of: item.pid).map(\.id))
    }

    var isOpen: Bool { !windows.isEmpty }
    var isTrackingMenu: Bool { windows.contains(where: \.isMenu) }

    enum State { case waiting, open, closed }

    /// Polls the owner's windows. `closed` once a menu was seen and is gone,
    /// or when nothing appeared within 1.5 s (an item with no menu).
    func poll() -> State {
        windows = Self.windows(of: item.pid).filter { !baseline.contains($0.id) }
        if !windows.isEmpty { sawMenu = true; return .open }
        if sawMenu || Date().timeIntervalSince(started) > 1.5 { return .closed }
        return .waiting
    }

    func contains(cocoaPoint point: NSPoint) -> Bool {
        let ax = CGPoint(x: point.x, y: BarReader.primaryHeight - point.y)
        return windows.contains { $0.bounds.insetBy(dx: -2, dy: -2).contains(ax) }
    }

    /// Closes the item's menu: Esc for a tracking NSMenu (the key goes to the
    /// menu), or pressing the item again for a popover-style window.
    func dismiss() {
        if isTrackingMenu {
            Self.postEscape()
        } else if isOpen {
            AX.press(item.pressElement)
        }
    }

    /// Moves a popover-style window (not an NSMenu) so it hangs under `anchor`
    /// (our panel icon) instead of under the item's parked overflow spot.
    /// Only windows that just appeared right under the bar; menus can't be moved.
    func realign(under anchor: NSRect, barBottomAX: CGFloat) {
        guard let window = windows.first(where: { !$0.isMenu && !realigned.contains($0.id) && abs($0.bounds.minY - barBottomAX) < 14 }) else { return }
        realigned.insert(window.id)
        let anchorMidX = anchor.midX
        var x = (anchorMidX - window.bounds.width / 2).rounded()
        // Keep it on the screen that holds the bar.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
            x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - window.bounds.width - 4)
        }
        guard abs(x - window.bounds.minX) > 6 else { return }
        let app = AXUIElementCreateApplication(item.pid)
        let axWindows = (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let match = axWindows.first(where: { el in
            guard let f = MenuBarEnumerator.frame(of: el) else { return false }
            return abs(f.minX - window.bounds.minX) < 3 && abs(f.minY - window.bounds.minY) < 3 && abs(f.width - window.bounds.width) < 3
        }) else {
            Log.write("Realign: no AX window matches \(window.bounds)")
            return
        }
        var point = CGPoint(x: x, y: window.bounds.minY)
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(match, kAXPositionAttribute as CFString, value)
        Log.write("Realign \(item.displayName) popover \(Int(window.bounds.minX)) → \(Int(x)): \(result.rawValue)")
    }

    // MARK: Helpers

    static func windows(of pid: pid_t) -> [OwnerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 4, bounds.height > 4 else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { return nil }
            return OwnerWindow(id: id, layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds)
        }
    }

    /// Set while we synthesize Esc, so our own key monitor ignores it.
    static var injectingEscapeUntil = Date.distantPast

    static func postEscape() {
        injectingEscapeUntil = Date().addingTimeInterval(0.3)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
