import AppKit
import ScreenCaptureKit

/// Screen captures of the menu bar (Screen Recording), taken in the
/// background while idle, never on click:
/// - the bar strip as it looks, used to cover the bar during the hand-off
///   (the stretch left of the arrow is empty background while items are hidden);
/// - the patch under macOS's « arrow, mirrored: exactly the native » on the
///   same background, for our open state.
/// Item images instead come from the "Menubar" window alone, whose
/// background is transparent (ItemImageCache).
@MainActor
final class BarCapture {
    /// Bar strip of the last captured screen, and the frame it covers (AX).
    private(set) var background: CGImage?
    private(set) var backgroundRectAX: CGRect = .zero
    /// The patch under macOS's « arrow, mirrored: » on the bar background.
    private(set) var expandedArrow: NSImage?
    private var lastCapture = Date.distantPast
    private var capturing = false

    var scale: CGFloat = 2

    /// The menu bar's item layer for `screen`, from ScreenCaptureKit.
    static func menubarWindow(in content: SCShareableContent, screen: BarReader.ScreenInfo) -> SCWindow? {
        content.windows.first {
            $0.title == "Menubar" && abs($0.frame.minX - screen.frame.minX) < 2 && abs($0.frame.minY - screen.axTop) < 2
        }
    }

    /// Refreshes the cached background and arrow glyph (throttled).
    func refreshIfNeeded(screen: BarReader.ScreenInfo?, arrow: CGRect?, force: Bool = false) {
        guard ItemImageCache.canCapture, let screen, !capturing else { return }
        guard force || Date().timeIntervalSince(lastCapture) > 20 else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false; lastCapture = Date() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }),
                      let bar = Self.menubarWindow(in: content, screen: screen) else { return }
                let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                scale = screen.scale

                // The bar as it looks (minus our own windows). macOS draws its
                // overflow arrow outside the "Menubar" layer, so separating
                // layers can't remove it; mirror the patch under it instead.
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: 0, y: 0, width: bar.frame.width, height: bar.frame.height)
                config.width = Int(bar.frame.width * scale)
                config.height = Int(bar.frame.height * scale)
                config.showsCursor = false
                background = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config)
                backgroundRectAX = bar.frame
                if let arrow, let patch = backgroundPatch(for: ArrowCatcher.coverRectAX(for: arrow)),
                   let cg = patch.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    expandedArrow = Self.mirrored(cg, size: patch.size)
                }
            } catch {
                Log.write("Bar capture failed: \(error.localizedDescription)")
            }
        }
    }

    static func captureLayer(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    /// Part of the cached background under `rectAX`, or nil if not cached.
    func backgroundPatch(for rectAX: CGRect) -> NSImage? {
        guard let background, backgroundRectAX.intersects(rectAX) else { return nil }
        let local = CGRect(x: (rectAX.minX - backgroundRectAX.minX) * scale, y: (rectAX.minY - backgroundRectAX.minY) * scale,
                           width: rectAX.width * scale, height: rectAX.height * scale).integral
        guard let cg = background.cropping(to: local) else { return nil }
        return NSImage(cgImage: cg, size: rectAX.size)
    }

    private static func mirrored(_ image: CGImage, size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: rect.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: rect)
            return true
        }
    }
}
