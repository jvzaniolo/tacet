import AppKit

/// Windows on screen from CGWindowList (owner PID, level and bounds need no
/// Screen Recording), used to tell whether a click landed in a menu or a
/// popover.
enum MenuTracker {
    struct OwnerWindow {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect   // top-left global (AX) coordinates
        var isMenu: Bool { layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) && layer < Int(CGWindowLevelForKey(.screenSaverWindow)) }
    }

    static func allWindows() -> [OwnerWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 4, bounds.height > 4,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            return OwnerWindow(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds)
        }
    }
}
