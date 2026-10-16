import AppKit
import ApplicationServices

/// One status item ("menu extra") as seen through Accessibility.
struct MenuBarItem: Identifiable {
    let id: String
    let element: AXUIElement
    /// The element that answers AXPress (the item itself or a descendant).
    let pressElement: AXUIElement
    let pid: pid_t
    let title: String?
    let itemDescription: String?
    let help: String?
    let identifier: String?
    let role: String?
    let subrole: String?
    let frame: CGRect?
    let actions: [String]

    var displayName: String {
        title ?? itemDescription ?? help ?? identifier ?? "(untitled)"
    }
}

/// All status items owned by one process.
struct MenuBarApp: Identifiable {
    var id: String { key }
    /// Persisted key: bundle ID when there is one, otherwise the process name.
    let key: String
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let isSystem: Bool
    var items: [MenuBarItem]
}

enum MenuBarEnumerator {

    /// Result of one scan.
    struct Scan {
        var apps: [MenuBarApp]
        /// macOS 27's own overflow arrow (MenuBarAgent), when found.
        var overflowButton: CGRect?
        var overflowFound: Bool
    }

    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    /// Walks every running process and collects its `AXExtrasMenuBar` children.
    /// Blocking: call off the main thread. Requires Accessibility.
    static func enumerate() -> Scan {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        // Items grouped by the process that owns them. On macOS 27 a child of
        // one process's extras bar can belong to another (MenuBarAgent hosts
        // items for others), so ownership comes from AXUIElementGetPid.
        var itemsByOwner: [pid_t: [MenuBarItem]] = [:]
        var overflowFrame: CGRect?
        var overflowFound = false

        for app in running where app.processIdentifier != ownPID {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            // A hung app must not stall the whole scan.
            AXUIElementSetMessagingTimeout(axApp, 0.3)

            guard let extras = AX.element(axApp, kAXExtrasMenuBarAttribute) else { continue }
            let isAgent = app.bundleIdentifier == menuBarAgentBundleID

            if isAgent, let overflow = AX.element(extras, "AXOverflowButton") {
                overflowFound = true
                overflowFrame = frame(of: overflow)
            }

            for (index, element) in AX.children(extras).enumerated() {
                // MenuBarAgent shows real items as AXGroup and its overflow
                // chevron as a bare AXButton.
                if isAgent, AX.string(element, kAXRoleAttribute) == kAXButtonRole {
                    overflowFound = true
                    overflowFrame = overflowFrame ?? frame(of: element)
                    continue
                }
                var ownerPID: pid_t = 0
                if AXUIElementGetPid(element, &ownerPID) != .success || ownerPID <= 0 { ownerPID = pid }
                if ownerPID == ownPID { continue }
                let key = byPID[ownerPID]?.bundleIdentifier ?? "pid\(ownerPID)"
                itemsByOwner[ownerPID, default: []].append(
                    makeItem(element, pid: ownerPID, fallbackID: "\(key)#\(pid)#\(index)"))
            }
        }

        let apps = itemsByOwner.compactMap { pid, items -> MenuBarApp? in
            let app = byPID[pid]
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName ?? bundleID ?? "pid \(pid)"
            return MenuBarApp(
                key: bundleID ?? name,
                pid: pid,
                name: name,
                bundleID: bundleID,
                icon: app?.icon,
                isSystem: bundleID?.hasPrefix("com.apple.") ?? false,
                items: items
            )
        }
        // Sort apps by their rightmost item so the list roughly mirrors the bar.
        .sorted { lhs, rhs in
            let l = lhs.items.compactMap { $0.frame?.minX }.max() ?? 0
            let r = rhs.items.compactMap { $0.frame?.minX }.max() ?? 0
            return l > r
        }
        return Scan(apps: apps, overflowButton: overflowFrame, overflowFound: overflowFound)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let p = AX.point(element), let s = AX.size(element) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func makeItem(_ element: AXUIElement, pid: pid_t, fallbackID: String) -> MenuBarItem {
        // MenuBarAgent wraps each item in an unnamed AXGroup/AXHostingView;
        // the name and the pressable element sit a level or two down.
        let named = firstDescendant(of: element) {
            AX.string($0, kAXIdentifierAttribute) != nil || AX.string($0, kAXTitleAttribute) != nil
                || AX.string($0, kAXDescriptionAttribute) != nil
        } ?? element
        let pressable = firstDescendant(of: element) { AX.actionNames($0).contains(kAXPressAction) }
        let identifier = AX.string(named, kAXIdentifierAttribute)
        return MenuBarItem(
            id: identifier.map { "\(pid)/\($0)" } ?? fallbackID,
            element: element,
            pressElement: pressable ?? element,
            pid: pid,
            title: AX.string(named, kAXTitleAttribute),
            itemDescription: AX.string(named, kAXDescriptionAttribute),
            help: AX.string(named, kAXHelpAttribute),
            identifier: identifier,
            role: AX.string(element, kAXRoleAttribute),
            subrole: AX.string(element, kAXSubroleAttribute),
            frame: frame(of: element),
            actions: AX.actionNames(pressable ?? element)
        )
    }

    /// Breadth-first search of `element` and its descendants, three levels deep.
    private static func firstDescendant(of element: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var level = [element]
        for _ in 0...3 {
            if let hit = level.first(where: match) { return hit }
            level = level.flatMap { AX.children($0) }
            if level.isEmpty { break }
        }
        return nil
    }

    /// Human-readable dump for the console / debug log.
    static func dump(_ scan: Scan) -> String {
        let apps = scan.apps
        var lines = ["MenuShelf: \(apps.count) apps with menu bar items, \(apps.reduce(0) { $0 + $1.items.count }) items"]
        lines.append("Native overflow arrow: \(scan.overflowFound ? "present \(scan.overflowButton.map { "\($0)" } ?? "(no frame)")" : "not found")")
        for app in apps {
            lines.append("• \(app.name) [\(app.bundleID ?? "no bundle id")] pid=\(app.pid)\(app.isSystem ? " (system)" : "")")
            for item in app.items {
                let frame = item.frame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "no frame"
                var parts = ["    - \(item.displayName)", frame]
                if let id = item.identifier { parts.append("id=\(id)") }
                if let d = item.itemDescription, d != item.displayName { parts.append("desc=\(d)") }
                if let r = item.role { parts.append("role=\(r)\(item.subrole.map { "/\($0)" } ?? "")") }
                parts.append("actions=\(item.actions.joined(separator: ","))")
                lines.append(parts.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
