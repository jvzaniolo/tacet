import AppKit
import QuartzCore

/// Shows the hidden items. Two placements:
/// - inline: in the empty bar area left of the arrow (notch displays free up
///   exactly the room the hidden items used), with no background, so the
///   icons look like they slid back onto the bar;
/// - dropdown: a rounded menu-material strip under the bar, right-aligned to
///   the arrow, when they don't fit inline.
/// Opens with a light spring (slight overshoot) plus fade, ~0.35 s.
@MainActor
final class RevealPanel {
    struct Entry {
        let item: MenuBarItem
        let image: NSImage
        let isCaptured: Bool
    }

    private let panel: NSPanel
    private let container = NSView()
    private let background = NSVisualEffectView()
    private(set) var isOpen = false
    var onPick: ((MenuBarItem) -> Void)?

    static let itemSpacing: CGFloat = 2
    static let iconHeight: CGFloat = 22

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        let root = NSView()
        root.wantsLayer = true
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        root.addSubview(background)
        container.wantsLayer = true
        root.addSubview(container)
        panel.contentView = root
    }

    var frame: NSRect { panel.frame }

    /// `arrow` and `boundary` are AX (top-left) coordinates.
    func open(entries: [Entry], arrow: CGRect, boundary: CGFloat, barTop: CGFloat, barHeight: CGFloat) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let views: [NSView] = entries.isEmpty ? [Self.emptyLabel()] : entries.map { entry in
            let button = ItemButton(entry: entry, height: barHeight)
            button.onPick = { [weak self] item in self?.onPick?(item) }
            return button
        }
        let contentWidth = views.reduce(0) { $0 + $1.frame.width } + Self.itemSpacing * CGFloat(max(views.count - 1, 0))

        let available = arrow.minX - 6 - boundary
        let inline = contentWidth <= available
        let padding: CGFloat = inline ? 0 : 6
        let width = contentWidth + padding * 2
        let height = inline ? barHeight : Self.iconHeight + 12
        let axFrame = inline
            ? CGRect(x: arrow.minX - 4 - width, y: barTop, width: width, height: barHeight)
            : CGRect(x: arrow.maxX - width, y: barTop + barHeight + 4, width: width, height: height)
        panel.setFrame(BarReader.cocoaRect(axFrame), display: false)

        background.isHidden = inline
        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        container.frame = background.frame
        var x = padding
        for view in views {
            view.frame.origin = NSPoint(x: x, y: (height - view.frame.height) / 2)
            container.addSubview(view)
            x += view.frame.width + Self.itemSpacing
        }

        isOpen = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        animateIn(from: inline ? CGPoint(x: 14, y: 0) : CGPoint(x: 0, y: 8))
    }

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Spring with a light bounce (damping ratio ≈ 0.7) on position, plus a
    /// quick fade.
    private func animateIn(from offset: CGPoint) {
        guard let layer = panel.contentView?.layer else { return }
        layer.removeAllAnimations()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = 340
        spring.damping = 26
        spring.initialVelocity = 0
        let start = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = min(spring.settlingDuration, 0.45)
        layer.add(spring, forKey: "spring")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    private static func emptyLabel() -> NSView {
        let label = NSTextField(labelWithString: "No hidden items — Edit Layout to ⌘-drag icons left of the divider")
        label.font = .menuBarFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.frame.size.width += 16
        return label
    }
}

/// One hidden item: its image, a hover highlight like the bar's, click to open.
private final class ItemButton: NSView {
    let entry: RevealPanel.Entry
    var onPick: ((MenuBarItem) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(entry: RevealPanel.Entry, height: CGFloat) {
        self.entry = entry
        let width = entry.isCaptured ? entry.image.size.width : 30
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: entry.isCaptured ? height : RevealPanel.iconHeight))
        toolTip = entry.item.displayName
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            let h: CGFloat = 24
            let r = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        }
        if entry.isCaptured {
            entry.image.draw(in: bounds)
        } else {
            let side: CGFloat = 18
            entry.image.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPick?(entry.item) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
