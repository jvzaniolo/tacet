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
    private var fitsStreak = 0

    static let autosaveName = "MenuShelfSpacer"
    static let editWidth: CGFloat = 22
    static let arrowAllowance: CGFloat = 53
    static let margin: CGFloat = 8
    static let maxWidth: CGFloat = 740

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

    /// Revealed: the hidden items are back on the real bar. The spacer
    /// shrinks to a small blank item where the arrow was (its right edge stays
    /// put), under ArrowCatcher's ».
    private(set) var isRevealed = false
    private var hiddenLength: CGFloat = 300

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        if revealed {
            hiddenLength = item.length
            item.length = Self.editWidth
        } else {
            item.length = hiddenLength
        }
        render()
    }

    /// Makes sure the spacer overflows. Returns true when the width changed.
    ///
    /// Only an AX frame read while the spacer *fits* is reliable (it grows
    /// leftward from a fixed right edge). Once it overflows, macOS reports it
    /// at a parked spot that depends on the layout, so an overflowed spacer is
    /// left alone: a little extra width costs nothing now that macOS's own
    /// expansion (and its gap) is never shown. While it fits, it grows to the
    /// measured threshold (`rightEdge − boundary − 53 pt` with an arrow already
    /// on the bar, ~30 pt more without), at least 24 pt per step.
    @discardableResult
    func fit(spacerFrame: CGRect, arrow: CGRect?, boundary: CGFloat, others: [CGRect]) -> Bool {
        guard !isEditing, !isRevealed, boundary > 0 else { return false }
        // While macOS relayouts the bar its arrow can be missing from AX for a
        // moment. Items parked inside our frame prove we are overflowed anyway
        // (nothing can sit on top of a spacer that is drawn on the bar).
        let parkedInside = others.contains { spacerFrame.insetBy(dx: 2, dy: -20).contains(CGPoint(x: $0.midX, y: spacerFrame.midY)) }
        let overflowed = (arrow.map { spacerFrame.minX < $0.minX } ?? false) || parkedInside
        guard !overflowed else {
            fitsStreak = 0
            if item.length > Self.maxWidth { item.length = Self.maxWidth; render(); return true }
            return false
        }
        // Grow only after two readings agree, so one odd read can't do it.
        fitsStreak += 1
        guard fitsStreak >= 2 else { return false }
        let rightEdge = spacerFrame.maxX
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
        let next = min(max(target, item.length + 24), Self.maxWidth)
        guard next != item.length else { return false }
        fitsStreak = 0
        Log.write("Spacer still fits: width \(Int(item.length)) → \(Int(next)) (right edge \(Int(rightEdge)), boundary \(Int(boundary)))")
        item.length = next
        render()
        return true
    }

    private func render() {
        let length = max(item.length, Self.editWidth)
        let editing = isEditing
        // Revealed: a blank slot. ArrowCatcher keeps drawing » (the mirrored
        // native arrow) in place over it, so the arrow never changes look.
        item.button?.toolTip = "MenuShelf divider — ⌘-drag icons to its left to hide them"
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
