import AppKit

/// A way to make whole apps' menu bar items disappear and come back.
@MainActor
protocol AppHiding: AnyObject {
    var isOperational: Bool { get }
    var statusText: String { get }
    /// Bundle IDs whose visibility changed since the app last launched; they
    /// may need a relaunch before the change shows.
    var needsRelaunch: Set<String> { get }
    /// Why `key` cannot be hidden, or nil when it can.
    func unsupportedReason(for app: MenuBarApp) -> String?
    /// Make exactly `hiddenKeys` hidden; restore every other app we touched.
    func apply(hiddenKeys: Set<String>, knownApps: [MenuBarApp])
    /// Called when an app (re)launches, so it no longer needs a relaunch.
    func appDidLaunch(bundleID: String)
}

@MainActor
func makeHider() -> AppHiding {
    // `--spike` keeps other apps' preferences untouched during experiments.
    CommandLine.arguments.contains("--spike") ? DisabledHider() : VisibleCCHider()
}

@MainActor
final class DisabledHider: AppHiding {
    let isOperational = false
    let statusText = "Hiding is off (launched with --spike)."
    let needsRelaunch: Set<String> = []
    func unsupportedReason(for app: MenuBarApp) -> String? { "Hiding is off (--spike)" }
    func apply(hiddenKeys: Set<String>, knownApps: [MenuBarApp]) {}
    func appDidLaunch(bundleID: String) {}
}

/// Hides an app's items through AppKit's per-item visibility switch.
///
/// On macOS 27 AppKit reads `NSStatusItem VisibleCC <autosaveName>` from the
/// owning app's preferences; when it is false the item is not published to
/// the menu bar. System Settings writes the same key when you turn an item
/// off there. MenuShelf sets it for every autosave name of a Hidden app and
/// records the original value so revealing puts back exactly what was there.
///
/// Limits (see NOTES-macos27.md):
/// - Only non-sandboxed apps: a sandboxed app reads its preferences from its
///   container, which other processes cannot write.
/// - Apple's own items (Control Center, Clock, …) are left alone.
/// - AppKit may only read the key when it creates the item, so the app may
///   need a relaunch before the change shows.
@MainActor
final class VisibleCCHider: AppHiding {
    let isOperational = true
    let statusText = "Experimental: hides by turning off each item's VisibleCC switch in the app's preferences. Apps may need a relaunch to pick up the change."

    private(set) var needsRelaunch: Set<String> = []

    /// bundleID → autosaveName → original VisibleCC value (nil = key was absent).
    /// Persisted so a crash or quit never strands an app hidden.
    private var ledger: [String: [String: Bool?]] {
        get { Self.loadLedger() }
        set { Self.saveLedger(newValue) }
    }

    private static let ledgerDefault = "visibleCCLedger"
    private static let visibleCCPrefix = "NSStatusItem VisibleCC "
    private static let namePrefixes = [
        "NSStatusItem VisibleCC ",
        "NSStatusItem Visible ",
        "NSStatusItem Preferred Position ",
    ]

    func unsupportedReason(for app: MenuBarApp) -> String? {
        guard let bundleID = app.bundleID else { return "No bundle ID" }
        if bundleID.hasPrefix("com.apple.") { return "Apple items are managed by System Settings" }
        if Self.isSandboxed(bundleID) { return "Sandboxed app: its preferences can't be changed from outside" }
        if Self.autosaveNames(for: bundleID, itemCount: app.items.count).isEmpty { return "No status item names found for this app yet" }
        return nil
    }

    func apply(hiddenKeys: Set<String>, knownApps: [MenuBarApp]) {
        var ledger = self.ledger
        let appsByKey = Dictionary(knownApps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        // Restore apps that should no longer be hidden.
        for bundleID in ledger.keys where !hiddenKeys.contains(bundleID) {
            for (name, original) in ledger[bundleID] ?? [:] {
                Self.setVisibleCC(original, name: name, bundleID: bundleID)
            }
            Self.synchronize(bundleID)
            ledger[bundleID] = nil
            needsRelaunch.insert(bundleID)
            Log.write("Restored VisibleCC for \(bundleID)")
        }

        // Hide apps that should be hidden (including names that appeared later).
        for bundleID in hiddenKeys {
            if let app = appsByKey[bundleID], let reason = unsupportedReason(for: app) {
                Log.write("Not hiding \(bundleID): \(reason)")
                continue
            }
            if appsByKey[bundleID] == nil, ledger[bundleID] == nil {
                // Not running and never hidden by us: nothing to do until it shows up.
                continue
            }
            var entries = ledger[bundleID] ?? [:]
            var changed = false
            for name in Self.autosaveNames(for: bundleID, itemCount: appsByKey[bundleID]?.items.count ?? 0) {
                if entries[name] == nil {
                    entries[name] = .some(Self.visibleCC(name: name, bundleID: bundleID))
                }
                if Self.visibleCC(name: name, bundleID: bundleID) != false {
                    Self.setVisibleCC(false, name: name, bundleID: bundleID)
                    changed = true
                }
            }
            guard !entries.isEmpty else { continue }
            ledger[bundleID] = entries
            if changed {
                Self.synchronize(bundleID)
                needsRelaunch.insert(bundleID)
                Log.write("Set VisibleCC=false for \(bundleID): \(entries.keys.sorted())")
            }
        }

        self.ledger = ledger
    }

    func appDidLaunch(bundleID: String) {
        needsRelaunch.remove(bundleID)
    }

    // MARK: - Preferences access

    /// Every autosave name the app has used for a status item, from its own
    /// preferences and from MenuBarAgent's position table. When neither has
    /// any, falls back to AppKit's default names for unnamed items
    /// ("Item-0", "Item-1", …), one per item seen through Accessibility.
    static func autosaveNames(for bundleID: String, itemCount: Int = 0) -> Set<String> {
        var names = Set<String>()
        let keys = CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for key in keys {
            for prefix in namePrefixes where key.hasPrefix(prefix) {
                names.insert(String(key.dropFirst(prefix.count)))
            }
        }
        // macOS 27: "status:<bundleID>::<autosaveName>" → position.
        if let table = CFPreferencesCopyAppValue("TrailingItemPreferredPositions" as CFString, "com.apple.MenuBarAgent" as CFString) as? [String: Any] {
            let prefix = "status:\(bundleID)::"
            for key in table.keys where key.hasPrefix(prefix) {
                names.insert(String(key.dropFirst(prefix.count)))
            }
        }
        if names.isEmpty, itemCount > 0 {
            names = Set((0..<itemCount).map { "Item-\($0)" })
        }
        return names
    }

    private static func visibleCC(name: String, bundleID: String) -> Bool? {
        CFPreferencesCopyAppValue((visibleCCPrefix + name) as CFString, bundleID as CFString) as? Bool
    }

    private static func setVisibleCC(_ value: Bool?, name: String, bundleID: String) {
        CFPreferencesSetAppValue((visibleCCPrefix + name) as CFString, value.map { $0 as CFBoolean as CFPropertyList }, bundleID as CFString)
    }

    private static func synchronize(_ bundleID: String) {
        CFPreferencesAppSynchronize(bundleID as CFString)
    }

    static func isSandboxed(_ bundleID: String) -> Bool {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)")
        return FileManager.default.fileExists(atPath: container.path)
    }

    // MARK: - Ledger persistence (plist-friendly: absent originals stored as a sentinel)

    private static let absent = "absent"

    private static func loadLedger() -> [String: [String: Bool?]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: ledgerDefault) as? [String: [String: Any]] else { return [:] }
        return raw.mapValues { names in
            names.mapValues { value -> Bool? in value as? Bool }
        }
    }

    private static func saveLedger(_ ledger: [String: [String: Bool?]]) {
        let raw: [String: [String: Any]] = ledger.mapValues { names in
            names.mapValues { value -> Any in value.map { $0 as Any } ?? absent }
        }
        UserDefaults.standard.set(raw, forKey: ledgerDefault)
    }
}

/// Quits and reopens an app so it re-reads its status item preferences.
/// Only ever run on an explicit user action.
@MainActor
enum AppRelauncher {
    static func relaunch(bundleID: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let url = running.bundleURL else {
            Log.write("Relaunch \(bundleID): not running")
            return
        }
        Log.write("Relaunching \(bundleID)")
        running.terminate()
        Task { @MainActor in
            for _ in 0..<50 where !running.isTerminated {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard running.isTerminated else {
                Log.write("Relaunch \(bundleID): app did not quit")
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }
}
