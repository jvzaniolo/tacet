import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusController: StatusItemController!
    private var settings: SettingsWindowController!
    private var onboarding: OnboardingController!
    private var rescanTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("MenuShelf starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        model = AppModel(hider: makeHider())
        settings = SettingsWindowController(model: model)
        statusController = StatusItemController(model: model) { [weak self] in self?.settings.show() }
        onboarding = OnboardingController { [weak self] in
            Log.write("Accessibility granted")
            self?.model.rescan(log: true)
            self?.settings.show()
        }

        Log.write("Accessibility trusted: \(AX.isTrusted(prompt: false))")
        onboarding.showIfNeeded()
        model.rescan(log: true)

        // Keep the list fresh as apps come and go.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Give a newly launched app a moment to add its status items.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.model.rescan() }
                }
            }
        }
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.rescan() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }
}
