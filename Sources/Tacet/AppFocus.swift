import AppKit

/// Bringing Tacet's windows forward (review §5.2: one place for it).
///
/// macOS 14+ only hands focus to an agent app (no Dock icon) when another app
/// yields it, so a window opened from the status menu came up in front but
/// inactive. While one of Tacet's windows is open Tacet is a regular app
/// (Dock icon, like System Settings; Ice and Thaw do the same) and can
/// activate itself. It goes back to an agent when its last window closes.
@MainActor
enum AppFocus {
    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // The status menu may still be closing: try again on the next turn.
        DispatchQueue.main.async {
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
