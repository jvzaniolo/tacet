import AppKit
import ScreenCaptureKit
@preconcurrency import ApplicationServices

/// `--debug` only: commands from `scripts/debug.swift` ("dev.menushelf.spike")
/// for the experiments in NOTES §11. Any local process could send these, so
/// they are never enabled in a normal launch.
///
///   state                       log state, hidden set, AX layout
///   conceal | reveal | edit | done
///   hide <id,id,…>              hide exactly these bundle IDs
///   showall | off               allow-everything assertion / no assertion
///   swapnaive <id,…>            E2: invalidate first, then activate
///   press <bundleID>            AXPress that app's first item, log menu frame
///   record <name> <seconds>     60 fps stream of the bar strip (needs Screen Recording)
@MainActor
enum DebugCommands {
    private static weak var shelf: ShelfController?
    private static var recorder: BarRecorder?

    static func install(shelf: ShelfController) {
        self.shelf = shelf
        Log.write("Debug commands enabled")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.menushelf.spike"), object: nil, queue: .main
        ) { note in
            let parts = (note.object as? String ?? "").split(separator: " ").map(String.init)
            MainActor.assumeIsolated { run(parts) }
        }
    }

    private static func ids(_ parts: [String]) -> Set<String> {
        Set((parts.dropFirst().first ?? "").split(separator: ",").map(String.init))
    }

    private static func run(_ parts: [String]) {
        guard let shelf else { return }
        Log.write("DEBUG \(parts.joined(separator: " "))")
        let r = shelf.restrictionForDebug
        switch parts.first {
        case "state": logLayout(shelf)
        case "conceal": shelf.conceal()
        case "reveal": shelf.reveal()
        case "edit": shelf.beginEditing()
        case "done": shelf.finishEditing()
        case "hide": r.set(.hiding(ids(parts)))
        case "showall": r.set(.showingAll)
        case "off": r.set(.off)
        case "swapnaive":
            // E2 comparison: drop the current assertion first, then activate.
            r.releaseAll()
            r.set(.hiding(ids(parts)))
        case "press": press(bundleID: parts.dropFirst().first ?? "")
        case "ccpick": ControlCenterSwitches.pick()
        case "ccdump": ControlCenterSwitches.dump()
        case "ccwatch": ControlCenterSwitches.watch(parts.count > 1 && parts[1] == "on")
        case "ccset":   // ccset <id,id,…> <0|1>
            ControlCenterSwitches.setAllowed(parts.count > 2 && parts[2] == "1", for: ids(parts))
        case "ccrestore": ControlCenterSwitches.restore()
        case "record":
            let name = parts.count > 1 ? parts[1] : "rec"
            let seconds = parts.count > 2 ? Double(parts[2]) ?? 2 : 2
            // Record the display whose bar holds our chevron.
            let frame = shelf.chevronForDebug.button?.window?.frame ?? .zero
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.screens[0]
            recorder = BarRecorder(name: name, displayID: screen.displayID, width: screen.frame.width)
            recorder?.start(seconds: seconds)
        default: break
        }
    }

    static func logLayout(_ shelf: ShelfController) {
        Task { @MainActor in
            let scan = await Task.detached { MenuBarEnumerator.enumerate(includeOwn: true) }.value
            var lines = ["DEBUG layout state=\(shelf.state) mode=\(Restriction.describe(shelf.restrictionForDebug.mode)) hidden=\(shelf.hidden.sorted()) arrow=\(scan.overflowButton.map { "\(Int($0.minX))" } ?? "none")"]
            let items = scan.apps.flatMap { app in app.items.map { (app, $0) } }.sorted { ($0.1.frame?.minX ?? 0) < ($1.1.frame?.minX ?? 0) }
            for (app, item) in items {
                lines.append("  \(item.frame.map { "\(Int($0.minX))+\(Int($0.width))@\(Int($0.minY))" } ?? "nil") \(app.bundleID ?? app.name): \(item.displayName)")
            }
            Log.write(lines.joined(separator: "\n"))
        }
    }

    private static func press(bundleID: String) {
        Task { @MainActor in
            let scan = await Task.detached { MenuBarEnumerator.enumerate(includeOwn: false) }.value
            guard let item = scan.apps.first(where: { $0.bundleID == bundleID })?.items.first else {
                Log.write("DEBUG press: \(bundleID) has no item"); return
            }
            let pid = item.pid
            let before = Set(MenuTracker.windows(of: pid).map(\.id))
            let element = item.pressElement
            let frame = item.frame
            DispatchQueue.global().async {
                AXUIElementSetMessagingTimeout(element, 0.5)
                let result = AX.press(element)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let new = MenuTracker.allWindows().filter { ($0.pid == pid && !before.contains($0.id)) || $0.isMenu }
                    Log.write("DEBUG press \(bundleID) → \(result.rawValue); item \(frame.map { "\(Int($0.minX))+\(Int($0.width))" } ?? "nil"); windows \(new.map { "\(Int($0.bounds.minX))+\(Int($0.bounds.width)) layer \($0.layer)" })")
                }
            }
        }
    }
}

/// Records the bar strip with an SCStream at 60 fps and writes PNG frames
/// with timestamps (ms since start) for the animation measurements.
final class BarRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let name: String
    private var stream: SCStream?
    private var frames: [(TimeInterval, CGImage)] = []
    private var started = Date()
    private let queue = DispatchQueue(label: "recorder")

    private let displayID: CGDirectDisplayID
    private let width: CGFloat

    init(name: String, displayID: CGDirectDisplayID, width: CGFloat) {
        self.name = name
        self.displayID = displayID
        self.width = width
    }

    func start(seconds: Double) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return }
                let config = SCStreamConfiguration()
                let left = width * 0.45
                config.sourceRect = CGRect(x: left, y: 0, width: width - left, height: 40)
                config.width = Int(width - left)
                config.height = 40
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.showsCursor = false
                config.queueDepth = 8
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                self.stream = stream
                started = Date()
                Log.write("DEBUG record \(name) started at \(Log.timestamp())")
                try await stream.startCapture()
                try await Task.sleep(for: .seconds(seconds))
                try await stream.stopCapture()
                write()
            } catch {
                Log.write("DEBUG record failed: \(error.localizedDescription)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        frames.append((Date().timeIntervalSince(started), cg))
    }

    private func write() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenuShelf/debug/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var index = ""
        for (i, (t, image)) in queue.sync(execute: { frames }).enumerated() {
            let url = dir.appendingPathComponent(String(format: "f%03d.png", i))
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try? data.write(to: url) }
            index += String(format: "%d %.1f\n", i, t * 1000)
        }
        try? index.write(to: dir.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        Log.write("DEBUG record \(name): \(frames.count) frames → \(dir.path)")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
