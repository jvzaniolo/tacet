import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ShelfModel()
    private lazy var shelf = ShelfController(model: model)
    private let hotkey = Hotkey()
    private let loginItem = LoginItem()
    private lazy var settings = SettingsWindowController(model: model, hotkey: hotkey, loginItem: loginItem)
    private var signalSources: [DispatchSourceSignal] = []
    private let expiredWindow = BetaExpiredWindowController()
    private var expiryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Tacet \(BuildInfo.shortVersion) (\(BuildInfo.build)) starting on macOS \(BuildInfo.macOSVersion)\(Bundle.main.bundlePath.hasPrefix("/Applications/") ? "" : ", outside /Applications")")
        Log.debug("Bundle: \(Bundle.main.bundlePath)")
        Log.write("Switches supported: \(MenuBarSwitches.isSupported)")
        quitCleanlyOnSignals()
        if let expiry = BuildInfo.betaExpiry { Log.write("Beta build \(BuildInfo.shortVersion) (\(BuildInfo.build)), expires \(expiry)") }
        model.start()
        shelf.openSettings = { [weak self] in self?.settings.show() }
        shelf.showExpired = { [weak self] in self?.expiredWindow.show() }
        if BuildInfo.isExpired {
            model.expire()
        }
        shelf.hotkey = hotkey
        shelf.start()
        hotkey.onPress = { [weak self] all in self?.shelf.toggle(all: all) }
        hotkey.start()
        loginItem.refresh()
        if model.expired {
            expiredWindow.show()
        } else if settings.needsWelcome {
            settings.show()
        }
        watchBetaExpiry()
    }

    /// A beta that expires while Tacet is running stops hiding at once.
    private func watchBetaExpiry() {
        guard BuildInfo.isBeta, !model.expired else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, BuildInfo.isExpired else { return }
                timer.invalidate()
                self.model.expire()
                self.shelf.conceal()
                self.expiredWindow.show()
            }
        }
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
