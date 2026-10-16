import AppKit
import ApplicationServices

/// One status item ("menu extra") as seen through Accessibility.
struct MenuBarItem: Identifiable {
    let id: String
    let element: AXUIElement
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
    /// Processes that host Apple's own menu extras on recent macOS.
    static let systemHostBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.TextInputMenuAgent",
        "com.apple.weather.menu",
    ]

    /// Walks every running process and collects its `AXExtrasMenuBar` children.
    /// Blocking: call off the main thread. Requires Accessibility.
    static func enumerate() -> [MenuBarApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [MenuBarApp] = []

        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            // A hung app must not stall the whole scan.
            AXUIElementSetMessagingTimeout(axApp, 0.3)

            guard let extras = AX.element(axApp, kAXExtrasMenuBarAttribute) else { continue }
            let children = AX.children(extras)
            guard !children.isEmpty else { continue }

            let bundleID = app.bundleIdentifier
            let name = app.localizedName ?? bundleID ?? "pid \(pid)"
            let key = bundleID ?? name
            let items = children.enumerated().map { index, element in
                makeItem(element, pid: pid, fallbackID: "\(key)#\(index)")
            }
            result.append(MenuBarApp(
                key: key,
                pid: pid,
                name: name,
                bundleID: bundleID,
                icon: app.icon,
                isSystem: bundleID.map { systemHostBundleIDs.contains($0) || $0.hasPrefix("com.apple.") } ?? false,
                items: items
            ))
        }

        // Rightmost item first is how the menu bar reads; sort apps by their
        // rightmost item's x so the list roughly mirrors the bar.
        return result.sorted { lhs, rhs in
            let l = lhs.items.compactMap { $0.frame?.minX }.max() ?? 0
            let r = rhs.items.compactMap { $0.frame?.minX }.max() ?? 0
            return l > r
        }
    }

    private static func makeItem(_ element: AXUIElement, pid: pid_t, fallbackID: String) -> MenuBarItem {
        let position = AX.point(element)
        let size = AX.size(element)
        let frame = position.flatMap { p in size.map { CGRect(origin: p, size: $0) } }
        let identifier = AX.string(element, kAXIdentifierAttribute)
        return MenuBarItem(
            id: identifier.map { "\(pid)/\($0)" } ?? fallbackID,
            element: element,
            pid: pid,
            title: AX.string(element, kAXTitleAttribute),
            itemDescription: AX.string(element, kAXDescriptionAttribute),
            help: AX.string(element, kAXHelpAttribute),
            identifier: identifier,
            role: AX.string(element, kAXRoleAttribute),
            subrole: AX.string(element, kAXSubroleAttribute),
            frame: frame,
            actions: AX.actionNames(element)
        )
    }

    /// Human-readable dump for the console / debug log.
    static func dump(_ apps: [MenuBarApp]) -> String {
        var lines = ["MenuShelf: \(apps.count) apps with menu bar items, \(apps.reduce(0) { $0 + $1.items.count }) items"]
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
