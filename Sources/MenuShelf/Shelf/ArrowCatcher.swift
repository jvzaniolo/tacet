import AppKit

/// A tiny transparent window over macOS's own overflow arrow. The arrow is
/// already the glyph we want (`chevron.backward.2`), so we keep it visible and
/// only take its clicks: left-click toggles our panel, right-click shows our
/// menu. While our panel is open we cover it with a pressed-state capsule and
/// `chevron.forward.2`, like the native control does when expanded.
@MainActor
final class ArrowCatcher {
    private let window: NSPanel
    private let view: CatcherView

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    init() {
        view = CatcherView()
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        view.onClick = { [weak self] in self?.onClick?() }
        view.onRightClick = { [weak self] event in self?.onRightClick?(event) }
    }

    /// Places the catcher over the arrow (AX frame), or hides it.
    func cover(arrow: CGRect?) {
        guard let arrow else {
            window.orderOut(nil)
            return
        }
        // A little wider and taller than the glyph, like the native hit area.
        let ax = Self.coverRectAX(for: arrow)
        window.setFrame(BarReader.cocoaRect(ax), display: true)
        window.orderFrontRegardless()
    }

    var frame: NSRect { window.frame }

    /// Keeps the catcher above our other bar windows.
    func bringToFront() { if window.isVisible { window.orderFrontRegardless() } }
    var isShown: Bool { window.isVisible }

    /// Open state: `cover` is a capture of the bar under the arrow, mirrored,
    /// so it shows » in macOS's own weight and colour on the same background
    /// and hides the « underneath; no capsule, like the native expanded
    /// control. Without Screen Recording, a capsule fallback.
    func setOpen(_ open: Bool, cover: NSImage? = nil) {
        view.cover = cover
        view.isOpen = open
    }

    /// Catcher rect in AX coordinates for `arrow` (for background patches).
    static func coverRectAX(for arrow: CGRect) -> CGRect {
        CGRect(x: arrow.minX - 6, y: arrow.minY - 1, width: arrow.width + 12, height: arrow.height + 2)
    }
}

private final class CatcherView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var isOpen = false { didSet { needsDisplay = true } }
    var cover: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        // Must not be fully transparent, or clicks fall through to the bar.
        NSColor.black.withAlphaComponent(0.005).setFill()
        bounds.fill()
        guard isOpen else { return }
        if let cover {
            cover.draw(in: bounds)
            return
        }
        let capsule = NSRect(x: 2, y: (bounds.height - 24) / 2, width: bounds.width - 4, height: 24)
        let path = NSBezierPath(roundedRect: capsule, xRadius: 12, yRadius: 12)
        // Opaque enough to hide the native « underneath.
        (effectiveAppearance.isDark ? NSColor(white: 0.32, alpha: 0.96) : NSColor(white: 0.86, alpha: 0.96)).setFill()
        path.fill()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let glyph = NSImage(systemSymbolName: "chevron.forward.2", accessibilityDescription: "Hide Menu Bar Items")?
            .withSymbolConfiguration(config) {
            let tinted = glyph.tinted(.labelColor)
            let size = tinted.size
            tinted.draw(in: NSRect(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick?(event) } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.isTemplate = false
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
