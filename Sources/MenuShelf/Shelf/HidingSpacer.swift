import AppKit

/// The divider status item. In normal mode it is sized just wide enough not
/// to fit, so macOS moves it, and every item left of it, into the native
/// overflow (truly hidden, no permission needed). In edit mode it shrinks to
/// a visible divider the user ⌘-drags to choose what is hidden.
///
/// Measured on macOS 27.0.1 (NOTES §9): the spacer grows leftward from a fixed
/// right edge and overflows once
///     width ≥ rightEdge − leadingBoundary − 53 pt
/// where rightEdge is its right edge while it fits. While overflowed its AX
/// frame sits 8 pt further left. Widths of ~800 pt or more misbehave (no
/// arrow, or the item is dropped), so the width is clamped well below that.
@MainActor
final class HidingSpacer {
    let item: NSStatusItem
    private(set) var isEditing = false
    private var lastUnhideableRightEdge: CGFloat?

    static let autosaveName = "MenuShelfSpacer"
    static let editWidth: CGFloat = 22
    static let arrowAllowance: CGFloat = 53
    static let margin: CGFloat = 8
    static let maxWidth: CGFloat = 740
    /// AX frame offset of an overflowed spacer vs. the same spacer fitting.
    static let overflowShift: CGFloat = 8

    init() {
        item = NSStatusBar.system.statusItem(withLength: 300)
        item.autosaveName = Self.autosaveName
        item.button?.imageScaling = .scaleNone
        item.button?.toolTip = "MenuShelf divider — ⌘-drag icons to its left to hide them"
        render()
    }

    var length: CGFloat { item.length }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing { item.length = Self.editWidth }
        render()
    }

    /// Recomputes the width from where the spacer sits now. Returns true when
    /// it changed. `arrow` tells whether the spacer is currently overflowed.
    @discardableResult
    func fit(spacerFrame: CGRect, arrow: CGRect?, boundary: CGFloat) -> Bool {
        guard !isEditing, boundary > 0 else { return false }
        let overflowed = arrow.map { spacerFrame.minX < $0.minX } ?? false
        let rightEdge = spacerFrame.maxX + (overflowed ? Self.overflowShift : 0)
        let target = (rightEdge - boundary - Self.arrowAllowance + Self.margin).rounded()
        // A display with more free space than a spacer can safely span (wide
        // external screens without a notch) can't hide anything. Leave the
        // width alone there: it keeps hiding on the notch display, and the
        // wide display simply shows everything.
        guard target <= Self.maxWidth else {
            if lastUnhideableRightEdge != rightEdge {
                lastUnhideableRightEdge = rightEdge
                Log.write("Spacer: \(Int(target)) pt needed here (right edge \(Int(rightEdge)), boundary \(Int(boundary))); over the \(Int(Self.maxWidth)) pt limit, keeping \(Int(item.length))")
            }
            return false
        }
        let clamped = max(target, Self.editWidth + 1)
        // Hysteresis: every change relayouts the bar.
        guard abs(clamped - item.length) > 3 else { return false }
        Log.write("Spacer width \(Int(item.length)) → \(Int(clamped)) (right edge \(Int(rightEdge)), boundary \(Int(boundary)), overflowed \(overflowed))")
        item.length = clamped
        render()
        return true
    }

    private func render() {
        let length = max(item.length, Self.editWidth)
        let editing = isEditing
        let image = NSImage(size: NSSize(width: length, height: 22), flipped: false) { rect in
            // Near-transparent fill so the item has real content.
            NSColor.black.withAlphaComponent(0.004).setFill()
            rect.fill()
            if editing {
                NSColor.labelColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - 1, y: 2, width: 2, height: 18), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        item.button?.image = image
    }
}
