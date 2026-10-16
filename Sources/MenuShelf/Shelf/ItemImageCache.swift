import AppKit
import ScreenCaptureKit

/// Images of menu bar items for the reveal panel.
///
/// Hidden items are not drawn anywhere, so they can only be captured while
/// they are on the bar: when the user finishes editing the layout (everything
/// is visible then), and once at launch if the cache is missing items.
/// Captures need Screen Recording; without it the panel shows app icons.
/// Never captures on click, so opening the panel stays instant.
@MainActor
final class ItemImageCache {
    private var images: [String: NSImage] = [:]
    /// Last-seen left-to-right order, so the panel matches the bar.
    private(set) var order: [String: CGFloat] = [:]

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("MenuShelf/ItemImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    init() {
        order = UserDefaults.standard.dictionary(forKey: "itemOrder") as? [String: CGFloat] ?? [:]
    }

    func image(for key: String) -> NSImage? {
        if let image = images[key] { return image }
        let url = fileURL(key)
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        images[key] = image
        return image
    }

    func hasImage(for key: String) -> Bool { image(for: key) != nil }

    /// Records the order of the given (visible) items.
    func rememberOrder(_ items: [MenuBarItem]) {
        for item in items { if let x = item.frame?.minX { order[BarReader.key(for: item)] = x } }
        UserDefaults.standard.set(order, forKey: "itemOrder")
    }

    /// Captures the bar strip of `screen` once and crops every item on it.
    func capture(_ items: [MenuBarItem], on screen: BarReader.ScreenInfo?) async {
        rememberOrder(items)
        guard Self.canCapture, let screen else { return }
        let onScreen = items.filter { $0.frame.map(screen.containsAX) ?? false }
        guard let barHeight = onScreen.compactMap({ $0.frame.map { ($0.midY - screen.axTop) * 2 } }).max(), barHeight > 10 else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
            let scale = screen.scale
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: barHeight)
            config.width = Int(screen.frame.width * scale)
            config.height = Int(barHeight * scale)
            config.showsCursor = false
            // Leave our own windows (panel, catcher) out of the picture.
            let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            var saved = 0
            for item in onScreen {
                guard let f = item.frame, f.width > 2 else { continue }
                let crop = CGRect(x: (f.minX - screen.frame.minX) * scale, y: 0, width: f.width * scale, height: barHeight * scale)
                guard let cg = strip.cropping(to: crop) else { continue }
                let image = NSImage(cgImage: cg, size: NSSize(width: f.width, height: barHeight))
                let key = BarReader.key(for: item)
                images[key] = image
                if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? data.write(to: fileURL(key))
                }
                saved += 1
            }
            Log.write("Captured \(saved) item images on display \(screen.displayID)")
        } catch {
            Log.write("Item capture failed: \(error.localizedDescription)")
        }
    }

    private func fileURL(_ key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(key.hashValue)
        return folder.appendingPathComponent(safe + ".png")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
