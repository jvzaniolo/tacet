import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ShelfModel()
    private lazy var shelf = ShelfController(model: model)
    private lazy var settings = SettingsWindowController(model: model)
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("MenuShelf starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) from \(Bundle.main.bundlePath)")
        Log.write("Switches supported: \(MenuBarSwitches.isSupported)")
        quitCleanlyOnSignals()
        model.start()
        shelf.openSettings = { [weak self] in self?.settings.show() }
        shelf.start()
        if settings.needsWelcome { settings.show() }
    }

    /// Restores the switches on quit, including at logout and shutdown.
    func applicationWillTerminate(_ notification: Notification) {
        shelf.prepareForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    /// `kill`, `killall` and Ctrl-C go through the normal quit, so hidden
    /// apps are turned back on. (SIGKILL can't be caught: the journal covers
    /// it on the next launch.)
    private func quitCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.write("Signal \(sig): quitting")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
