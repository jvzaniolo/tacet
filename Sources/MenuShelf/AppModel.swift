import AppKit
import Observation

/// Shared state: the last scan, which apps are "Hidden", and whether the
/// hidden apps are currently revealed.
@MainActor
@Observable
final class AppModel {
    private(set) var apps: [MenuBarApp] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var hasAccessibility = AX.isTrusted(prompt: false)

    /// Keys (bundle IDs) the user marked Hidden. Persisted.
    private(set) var hiddenKeys: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenKeys).sorted(), forKey: Self.hiddenKeysDefault) }
    }

    /// True while the user has the hidden apps revealed via the status item.
    private(set) var isRevealed = false

    let hider: AppHiding

    /// Settings window filter (kept here; see SettingsView).
    var showSystemItems = true

    private static let hiddenKeysDefault = "hiddenBundleIDs"

    init(hider: AppHiding) {
        self.hider = hider
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKeysDefault) ?? [])
    }

    var hiddenApps: [MenuBarApp] { apps.filter { hiddenKeys.contains($0.key) } }

    func isHidden(_ app: MenuBarApp) -> Bool { hiddenKeys.contains(app.key) }

    func setHidden(_ hidden: Bool, for app: MenuBarApp) {
        if hidden { hiddenKeys.insert(app.key) } else { hiddenKeys.remove(app.key) }
        applyVisibility()
    }

    func toggleRevealed() {
        isRevealed.toggle()
        applyVisibility()
    }

    /// Pushes the current Hidden set to the hiding backend.
    func applyVisibility() {
        let keysToHide = isRevealed ? [] : hiddenKeys
        hider.apply(hiddenKeys: keysToHide, knownApps: apps)
    }

    func refreshPermission() {
        hasAccessibility = AX.isTrusted(prompt: false)
    }

    func rescan(log: Bool = false) {
        refreshPermission()
        guard hasAccessibility, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let apps = MenuBarEnumerator.enumerate()
            if log { Log.write(MenuBarEnumerator.dump(apps)) }
            await MainActor.run {
                self.apps = apps
                self.isScanning = false
                self.lastScan = Date()
            }
        }
    }

    func dumpToConsole() {
        Log.write(MenuBarEnumerator.dump(apps))
    }
}
