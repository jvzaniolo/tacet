import AppKit

/// An opaque copy of the bar background laid over part of the menu bar, so
/// macOS can move items around underneath without anyone seeing it.
@MainActor
final class CoverWindow {
    private let window: NSPanel
    private let imageView = NSImageView()

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        imageView.imageScaling = .scaleAxesIndependently
        window.contentView = imageView
    }

    var isShown: Bool { window.isVisible }

    /// Shows `image` over `rectAX` (AX coordinates). Returns false without an image.
    @discardableResult
    func show(_ image: NSImage?, over rectAX: CGRect, fadeIn: TimeInterval = 0) -> Bool {
        guard let image else { return false }
        imageView.image = image
        window.setFrame(BarReader.cocoaRect(rectAX), display: true)
        window.alphaValue = fadeIn > 0 ? 0 : 1
        window.orderFrontRegardless()
        if fadeIn > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeIn
                window.animator().alphaValue = 1
            }
        }
        return true
    }

    func hide(fade: TimeInterval = 0) {
        guard window.isVisible else { return }
        guard fade > 0 else { window.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.window.orderOut(nil)
                self?.window.alphaValue = 1
            }
        })
    }
}
