import AppKit

/// Brings one of Tacet's windows forward, focused (review §5.2: one place
/// for it). A plain activation is enough as long as it isn't requested from
/// inside a mouse-down tracking loop: the arrow opens its menu on mouse-up
/// for that reason (ShelfController, NOTES §18).
@MainActor
enum AppFocus {
    static func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
