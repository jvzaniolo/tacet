import AppKit

/// Launch modes:
/// - default: MenuShelf v1 (spacer + arrow catcher + reveal panel).
/// - `--legacy`: the first prototype (own chevron, per-app VisibleCC hiding,
///   list window). Kept for comparison; not part of the product.
/// - `--spike`: legacy UI plus the spike controller driven by scripts/spike.swift.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var settings: SettingsWindowController!
    private var onboarding: OnboardingController!
    private var shelf: ShelfController?
    private var legacyStatus: StatusItemController?
    private var spike: SpikeController?
    private var rescanTimer: Timer?

    private var isLegacy: Bool {
        CommandLine.arguments.contains("--legacy") || CommandLine.arguments.contains("--spike")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("MenuShelf starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) mode=\(isLegacy ? "legacy" : "shelf")")
        model = AppModel(hider: isLegacy ? makeHider() : DisabledHider())
        settings = SettingsWindowController(model: model)
        onboarding = OnboardingController { [weak self] in
            Log.write("Accessibility granted")
            self?.model.rescan(log: true)
            self?.shelf?.refresh()
        }
        Log.write("Accessibility trusted: \(AX.isTrusted(prompt: false)), screen recording: \(CGPreflightScreenCaptureAccess())")
        onboarding.showIfNeeded()

        if isLegacy {
            startLegacy()
        } else {
            let shelf = ShelfController()
            shelf.openPermissions = { [weak self] in self?.onboarding.show() }
            shelf.openDiagnostics = { [weak self] in self?.settings.show() }
            shelf.start()
            self.shelf = shelf
        }
    }

    private func startLegacy() {
        if CommandLine.arguments.contains("--spike") { spike = SpikeController() }
        legacyStatus = StatusItemController(model: model) { [weak self] in self?.settings.show() }
        model.rescan(log: true) { [weak self] _ in self?.model.applyVisibility() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didLaunchApplicationNotification, let id = app?.bundleIdentifier {
                        self?.model.appDidLaunch(bundleID: id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.model.rescan() }
                }
            }
        }
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.rescan() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelf?.prepareForTermination()
        if isLegacy {
            // Never leave apps hidden without MenuShelf around to reveal them.
            model.hider.apply(hiddenKeys: [], knownApps: model.apps)
            Log.write("MenuShelf quitting: restored all hidden apps")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboarding.show()
        return true
    }
}
