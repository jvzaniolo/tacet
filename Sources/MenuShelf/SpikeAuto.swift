import AppKit
import ApplicationServices

/// Spike part 2: size the spacer live so it just overflows, and measure the
/// gap it leaves in the expanded overflow. AX is used to measure; the spacer's
/// own window frame is logged alongside to judge an Accessibility-free source.
struct BarGeometry {
    var boundary: CGFloat            // notch right edge, or end of app menus
    var boundarySource: String
    var expansionLimit: CGFloat      // right edge of the area the overflow expands into
    var arrow: CGRect?
    var expanded: Bool
    var spacerAX: CGRect?
    var spacerOverflowed: Bool
    var firstVisible: CGFloat?       // left edge of the first visible item right of the spacer/arrow
    var revealedMaxX: CGFloat?       // right edge of the rightmost revealed icon (expanded only)
    var ownWindow: CGRect?           // spacer's own NSWindow frame (no AX needed)
}

extension SpikeController {
    static let hideLabels: Set<String> = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        guard let table = NSDictionary(contentsOf: url) as? [String: [String: Any]] else { return ["Hide Menu Bar Items"] }
        return Set(table.values.compactMap { $0["menuBar.hideOverflowItemsAccessibilityLabel"] as? String })
    }()

    var tunables: (margin: CGFloat, calib: CGFloat, maxSafe: CGFloat) {
        let d = UserDefaults.standard
        return (CGFloat(d.object(forKey: "spikeMargin") as? Double ?? 4),
                CGFloat(d.object(forKey: "spikeCalib") as? Double ?? 0),
                CGFloat(d.object(forKey: "spikeMaxSafe") as? Double ?? 700))
    }

    func geometry() -> BarGeometry {
        let scan = MenuBarEnumerator.enumerate(includeOwn: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        var boundary: CGFloat = 0
        var source = "none"
        var limit: CGFloat = 0
        if let right = screen?.auxiliaryTopRightArea, let left = screen?.auxiliaryTopLeftArea {
            boundary = right.minX
            limit = left.maxX
            source = "notch"
        } else if let front = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            if let bar = AX.element(app, kAXMenuBarAttribute) {
                boundary = AX.children(bar).compactMap { MenuBarEnumerator.frame(of: $0)?.maxX }.max() ?? 0
                source = "app-menus(\(front.localizedName ?? "?"))"
            }
            limit = boundary
        }
        let arrowLabel = scan.overflowElement.flatMap { AX.string($0, kAXDescriptionAttribute) }
        let expanded = arrowLabel.map { Self.hideLabels.contains($0) } ?? false

        let length = spacer?.length ?? -1
        let own = scan.apps.filter { $0.pid == ownPID }.flatMap(\.items)
        let spacerItem = own.min { abs(($0.frame?.width ?? 0) - length - 2) < abs(($1.frame?.width ?? 0) - length - 2) }
        let spacerAX = spacer == nil ? nil : spacerItem?.frame
        let arrow = scan.overflowButton
        let spacerOverflowed = spacerAX.map { s in arrow.map { s.minX < $0.minX } ?? false } ?? false

        let others = scan.apps.filter { $0.pid != ownPID }.flatMap(\.items).compactMap(\.frame)
        let rightOf = arrow?.maxX ?? (spacerAX?.maxX ?? boundary)
        let firstVisible = others.filter { $0.minX >= rightOf - 1 && $0.minY < 30 }.map(\.minX).min()
        let revealed = expanded ? others.filter { $0.maxX <= limit + 1 }.map(\.maxX).max() : nil

        return BarGeometry(boundary: boundary, boundarySource: source, expansionLimit: limit, arrow: arrow,
                           expanded: expanded, spacerAX: spacerAX, spacerOverflowed: spacerOverflowed,
                           firstVisible: firstVisible, revealedMaxX: revealed, ownWindow: spacer?.button?.window?.frame)
    }

    func describeGeometry() -> String {
        let g = geometry()
        func r(_ rect: CGRect?) -> String { rect.map { "\(Int($0.minX))+\(Int($0.width))" } ?? "nil" }
        var s = "geo len=\(Int(spacer?.length ?? -1)) boundary=\(Int(g.boundary))[\(g.boundarySource)] limit=\(Int(g.expansionLimit)) arrow=\(r(g.arrow)) expanded=\(g.expanded) spacerAX=\(r(g.spacerAX)) overflowed=\(g.spacerOverflowed) firstVisible=\(g.firstVisible.map { "\(Int($0))" } ?? "nil") ownWindow=\(r(g.ownWindow))"
        if g.expanded {
            let gapToNotch = g.revealedMaxX.map { g.expansionLimit - $0 }
            s += " revealedMaxX=\(g.revealedMaxX.map { "\(Int($0))" } ?? "nil") GAP=\(gapToNotch.map { "\(Int($0))pt" } ?? "?")"
        }
        return s
    }

    // MARK: Calibration sweep

    func sweep(from: CGFloat, to: CGFloat, step: CGFloat) {
        Task { @MainActor in
            var w = from
            while (step > 0 ? w <= to : w >= to) {
                spacer?.length = w
                try? await Task.sleep(for: .milliseconds(1200))
                log("sweep \(describeGeometry())")
                w += step
            }
            log("sweep done")
        }
    }

    // MARK: Live auto-sizer

    func setAuto(_ on: Bool) {
        autoTimer?.invalidate()
        autoTimer = nil
        guard on else { log("auto off"); return }
        log("auto on tunables=\(tunables)")
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoTick() }
        }
    }

    /// target = (first visible item's left edge − boundary) − calib + margin,
    /// clamped to the safe band. Applied with 3 pt hysteresis, at most once a
    /// second, never while the overflow is expanded.
    private func autoTick() {
        guard let spacer else { return }
        let g = geometry()
        let t = tunables
        guard !g.expanded else { return }
        guard let first = g.firstVisible else { return }
        let free = first - g.boundary
        let target = min(max(free - t.calib + t.margin, 8), t.maxSafe)
        let clamped = free - t.calib + t.margin > t.maxSafe
        guard abs(target - spacer.length) > 3, Date().timeIntervalSince(lastApply) > 1 else { return }
        log("auto: free=\(Int(free)) target=\(Int(target))\(clamped ? " CLAMPED(maxSafe)" : "") from len=\(Int(spacer.length)) | \(describeGeometry())")
        spacer.length = target
        lastApply = Date()
    }
}
