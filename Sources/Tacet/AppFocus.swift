import AppKit

/// Bringing Tacet's windows forward (review §5.2: one place for it).
///
/// macOS 14+ only hands focus to an agent app (no Dock icon) when another app
/// yields it, so a window opened from the status menu came up in front but
/// inactive. While one of Tacet's windows is open Tacet is a regular app
/// (Dock icon, like System Settings; Ice and Thaw do the same) and can
/// activate itself (see `show`). It goes back to an agent when its last
/// window closes.
@MainActor
enum AppFocus {
    /// `NSApp.activate()` alone leaves the window in front but inactive
    /// (tested: the frontmost app stays the previous one). Activating the
    /// Dock first, as Ice does, makes macOS accept Tacet's activation right
    /// after, even when it doesn't follow a click (tested from a notification).
    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current {
                NSRunningApplication.current.activate(from: front, options: [])
            }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// From a window's `willClose`: back to an agent unless another of
    /// Tacet's windows is still open.
    static func windowClosing(_ closing: NSWindow) {
        let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
