import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shelf = ShelfController()
    private var onboarding: OnboardingController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("MenuShelf starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) from \(Bundle.main.bundlePath)")
        Log.write("Assertion API available: \(Restriction.isAvailable); Accessibility: \(AX.isTrusted(prompt: false))")
        onboarding = OnboardingController { Log.write("Accessibility granted") }
        shelf.openPermissions = { [weak self] in self?.onboarding.show() }
        shelf.start()
        // Accessibility is needed only to read the layout when you finish
        // editing, so ask for it up front only on first run.
        if !UserDefaults.standard.bool(forKey: "didEditLayoutOnce") { onboarding.showIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shelf.prepareForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboarding.show()
        return true
    }
}
