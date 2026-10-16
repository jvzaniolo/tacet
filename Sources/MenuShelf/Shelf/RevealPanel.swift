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
    /// Opaque copy of the bar background, shown during the hand-off to the
    /// real bar so the items moving underneath can't be seen.
    private let backdrop = NSImageView()
    private(set) var isOpen = false
    /// Where the open animation started from; the close animation returns there.
    private var openOffset = CGPoint(x: 14, y: 0)
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
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.isHidden = true
        root.addSubview(backdrop)
        container.wantsLayer = true
        root.addSubview(container)
        panel.contentView = root
    }

    var frame: NSRect { panel.frame }

    /// Screen (Cocoa) frame of each item button, for hover-switching.
    var itemFrames: [(item: MenuBarItem, frame: NSRect)] {
        container.subviews.compactMap { view in
            guard let button = view as? ItemButton, let window = button.window else { return nil }
            return (button.entry.item, window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
    }

    /// Shows `item` in the pressed state (like a menu bar item whose menu is open).
    func setPressed(_ item: MenuBarItem?) {
        let key = item.map(BarReader.key(for:))
        for case let button as ItemButton in container.subviews {
            button.isPressed = key != nil && BarReader.key(for: button.entry.item) == key
        }
    }

    /// `arrow` and `boundary` are AX (top-left) coordinates.
    /// `naturalX`: each item's x on the bar when last seen (by key), so the
    /// panel reproduces the real spacing and the hand-off doesn't shift icons.
    func open(entries: [Entry], arrow: CGRect, boundary: CGFloat, barTop: CGFloat, barHeight: CGFloat,
              naturalX: [String: CGFloat] = [:]) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let views: [NSView] = entries.isEmpty ? [Self.emptyLabel()] : entries.map { entry in
            let button = ItemButton(entry: entry, height: barHeight)
            button.onPick = { [weak self] item in self?.onPick?(item) }
            return button
        }
        // Gap after each view: the real bar's spacing when known, else 2 pt.
        var gaps: [CGFloat] = []
        for (i, view) in views.enumerated() {
            guard i + 1 < views.count, let a = view as? ItemButton, let b = views[i + 1] as? ItemButton,
                  let xa = naturalX[BarReader.key(for: a.entry.item)], let xb = naturalX[BarReader.key(for: b.entry.item)],
                  a.entry.isCaptured, b.entry.isCaptured else { gaps.append(Self.itemSpacing); continue }
            gaps.append(min(max(xb - xa - view.frame.width, 0), 24))
        }
        let contentWidth = views.reduce(0) { $0 + $1.frame.width } + gaps.reduce(0, +)

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
        backdrop.frame = background.frame
        backdrop.isHidden = true
        container.frame = background.frame
        var x = padding
        for (i, view) in views.enumerated() {
            view.frame.origin = NSPoint(x: x, y: (height - view.frame.height) / 2)
            container.addSubview(view)
            x += view.frame.width + (i < gaps.count ? gaps[i] : 0)
        }

        isOpen = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        openOffset = inline ? CGPoint(x: 14, y: 0) : CGPoint(x: 0, y: 8)
        animateIn(from: openOffset)
    }

    /// The open animation in reverse: slide back toward the arrow and fade,
    /// together. Ease-in without a bounce (a bounce on close reads as a glitch).
    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        guard animated, let layer = panel.contentView?.layer else { panel.orderOut(nil); return }
        let duration = 0.2
        let end = CATransform3DMakeTranslation(openOffset.x, openOffset.y, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }
        }
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.toValue = NSValue(caTransform3D: end)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        for animation in [slide, fade] as [CABasicAnimation] {
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        layer.transform = end
        layer.opacity = 0
        layer.add(slide, forKey: "closeSlide")
        layer.add(fade, forKey: "closeFade")
        CATransaction.commit()
    }

    /// Covers the bar under the panel with `image` (or removes the cover).
    func setBackdrop(_ image: NSImage?) {
        backdrop.image = image
        backdrop.isHidden = image == nil
    }

    /// Slides each icon to the screen x of its real item (AX x), so the
    /// hand-off to the real bar lands without a jump.
    func moveItems(toAX xs: [String: CGFloat], duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for case let button as ItemButton in container.subviews {
                guard let x = xs[BarReader.key(for: button.entry.item)] else { continue }
                let localX = x - panel.frame.minX - container.frame.minX
                button.animator().setFrameOrigin(NSPoint(x: localX, y: button.frame.minY))
            }
        }
    }

    /// Leaves without the close slide: used when the real bar takes over.
    func handOff(duration: TimeInterval) {
        guard isOpen else { return }
        isOpen = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.setBackdrop(nil)
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
    var isPressed = false { didSet { needsDisplay = true } }

    init(entry: RevealPanel.Entry, height: CGFloat) {
        self.entry = entry
        let width = entry.isCaptured ? entry.image.size.width : 30
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: entry.isCaptured ? height : RevealPanel.iconHeight))
        toolTip = entry.item.displayName
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isPressed {
            let h: CGFloat = 24
            let r = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.22 : 0.12).setFill()
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
