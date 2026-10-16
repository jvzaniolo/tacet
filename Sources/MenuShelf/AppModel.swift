import AppKit
import Observation

/// Shared state: the last scan, which apps are "Hidden", and whether the
/// hidden apps are currently revealed.
@MainActor
@Observable
final class AppModel {
    private(set) var apps: [MenuBarApp] = []
    private(set) var overflowFound = false
    private(set) var overflowFrame: CGRect?
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var hasAccessibility = AX.isTrusted(prompt: false)

    /// Keys (bundle IDs) the user marked Hidden. Persisted.
    private(set) var hiddenKeys: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenKeys).sorted(), forKey: Self.hiddenKeysDefault) }
    }

    /// True while the user has the hidden apps revealed via the status item.
    private(set) var isRevealed = false

    /// Bumped after every apply so views re-read the hider's state.
    private(set) var hiderGeneration = 0

    let hider: AppHiding

    /// Settings window filter (kept here; see SettingsView).
    var showSystemItems = true

    private static let hiddenKeysDefault = "hiddenBundleIDs"

    init(hider: AppHiding) {
        self.hider = hider
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKeysDefault) ?? [])
    }

    /// Hidden apps, including ones whose items no longer show up in the scan
    /// (an unpublished item has no AX element), so they can still be un-hidden.
    var hiddenApps: [MenuBarApp] {
        apps.filter { hiddenKeys.contains($0.key) } + missingHiddenApps
    }

    /// Everything the Settings list shows.
    var listedApps: [MenuBarApp] { apps + missingHiddenApps }

    private var missingHiddenApps: [MenuBarApp] {
        let seen = Set(apps.map(\.key))
        return hiddenKeys.subtracting(seen).sorted().map { key in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: key).first
            return MenuBarApp(
                key: key,
                pid: running?.processIdentifier ?? 0,
                name: running?.localizedName ?? key,
                bundleID: key,
                icon: running?.icon,
                isSystem: key.hasPrefix("com.apple."),
                items: []
            )
        }
    }

    var appsNeedingRelaunch: [MenuBarApp] {
        _ = hiderGeneration
        return apps.filter { hider.needsRelaunch.contains($0.key) }
    }

    func isHidden(_ app: MenuBarApp) -> Bool { hiddenKeys.contains(app.key) }

    func unsupportedReason(for app: MenuBarApp) -> String? {
        _ = hiderGeneration
        return hider.unsupportedReason(for: app)
    }

    func setHidden(_ hidden: Bool, for app: MenuBarApp) {
        if hidden { hiddenKeys.insert(app.key) } else { hiddenKeys.remove(app.key) }
        applyVisibility()
    }

    func toggleRevealed() {
        isRevealed.toggle()
        applyVisibility()
    }

    /// Pushes the current Hidden set to the hiding backend, then rescans to
    /// record whether the change showed up without a relaunch.
    func applyVisibility() {
        let keysToHide = isRevealed ? [] : hiddenKeys
        let before = Dictionary(apps.map { ($0.key, $0.items.count) }, uniquingKeysWith: { a, _ in a })
        hider.apply(hiddenKeys: keysToHide, knownApps: apps)
        hiderGeneration += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.rescan { scan in
                for app in scan.apps where self?.hider.needsRelaunch.contains(app.key) == true {
                    let frames = app.items.map { $0.frame.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "nil" }
                    Log.write("After apply: \(app.key) has \(app.items.count) AX items (was \(before[app.key] ?? 0)), frames \(frames)")
                }
            }
        }
    }

    func relaunch(_ app: MenuBarApp) {
        guard let bundleID = app.bundleID else { return }
        AppRelauncher.relaunch(bundleID: bundleID)
    }

    func appDidLaunch(bundleID: String) {
        hider.appDidLaunch(bundleID: bundleID)
        hiderGeneration += 1
    }

    func refreshPermission() {
        hasAccessibility = AX.isTrusted(prompt: false)
    }

    func rescan(log: Bool = false, then completion: ((MenuBarEnumerator.Scan) -> Void)? = nil) {
        refreshPermission()
        guard hasAccessibility, !isScanning else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let scan = MenuBarEnumerator.enumerate()
            if log { Log.write(MenuBarEnumerator.dump(scan)) }
            await MainActor.run {
                self.apps = scan.apps
                self.overflowFound = scan.overflowFound
                self.overflowFrame = scan.overflowButton
                self.isScanning = false
                self.lastScan = Date()
                // Hidden apps that launched since the last apply get hidden too.
                if !self.isRevealed, !self.hiddenKeys.isEmpty {
                    self.hider.apply(hiddenKeys: self.hiddenKeys, knownApps: scan.apps)
                }
                completion?(scan)
            }
        }
    }

    func dumpToConsole() {
        Log.write(MenuBarEnumerator.dump(MenuBarEnumerator.Scan(
            apps: apps, overflowButton: overflowFrame, overflowFound: overflowFound)))
    }
}
