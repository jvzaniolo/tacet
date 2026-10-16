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

    /// Records positions measured on a settled layout (by key).
    func rememberPositions(_ xs: [String: CGFloat]) {
        for (key, x) in xs { order[key] = x }
        UserDefaults.standard.set(order, forKey: "itemOrder")
    }

    /// Records the order of the given (visible) items.
    func rememberOrder(_ items: [MenuBarItem]) {
        for item in items { if let x = item.frame?.minX { order[BarReader.key(for: item)] = x } }
        UserDefaults.standard.set(order, forKey: "itemOrder")
    }

    /// Captures the menu bar's item layer once and crops every item on it.
    /// The layer has a transparent background, so the images carry no bar
    /// tint and sit cleanly on any background (no boxes behind icons).
    func capture(_ items: [MenuBarItem], on screen: BarReader.ScreenInfo?) async {
        guard Self.canCapture, let screen else { return }
        let onScreen = items.filter { $0.frame.map(screen.containsAX) ?? false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let bar = BarCapture.menubarWindow(in: content, screen: screen) else {
                Log.write("Item capture: no Menubar window for display \(screen.displayID)")
                return
            }
            let scale = screen.scale
            let layer = try await BarCapture.captureLayer(bar, scale: scale)
            var saved = 0
            for item in onScreen {
                guard let f = item.frame, f.width > 2 else { continue }
                let crop = CGRect(x: (f.minX - bar.frame.minX) * scale, y: 0, width: f.width * scale, height: bar.frame.height * scale).integral
                guard let cg = layer.cropping(to: crop) else { continue }
                let image = NSImage(cgImage: cg, size: NSSize(width: f.width, height: bar.frame.height))
                let key = BarReader.key(for: item)
                images[key] = image
                if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? data.write(to: fileURL(key))
                }
                saved += 1
            }
            Log.write("Captured \(saved) item images (transparent) on display \(screen.displayID)")
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

// MARK: - Debug: capture each menu bar window on its own (`--debug`, "barwindows")

extension ItemImageCache {
    static func debugCaptureBarWindows() async {
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenuShelf/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let bar = content.windows.filter { $0.frame.minY < 2 && $0.frame.height < 60 && $0.frame.width > 600 }
            for (i, window) in bar.enumerated() {
                let owner = window.owningApplication?.bundleIdentifier ?? "nil"
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.backgroundColor = .clear
                let filter = SCContentFilter(desktopIndependentWindow: window)
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let url = out.appendingPathComponent("bar-\(i)-\(owner)-layer\(window.windowLayer).png")
                    if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try? data.write(to: url) }
                    Log.write("DEBUG barwindow \(i) owner=\(owner) title=\(window.title ?? "") layer=\(window.windowLayer) frame=\(window.frame) alphaInfo=\(image.alphaInfo.rawValue) → \(url.lastPathComponent)")
                } catch {
                    Log.write("DEBUG barwindow \(i) owner=\(owner) capture failed: \(error.localizedDescription)")
                }
            }
        } catch {
            Log.write("DEBUG barwindows failed: \(error.localizedDescription)")
        }
    }
}
