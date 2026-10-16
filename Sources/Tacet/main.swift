import AppKit

MainActor.assumeIsolated {
    // LSUIElement in Info.plist makes Tacet an agent app (no Dock icon).
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
