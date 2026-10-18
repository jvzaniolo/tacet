import AppKit

/// The "Allow in the Menu Bar" switches of System Settings › Menu Bar
/// (NOTES §12–13), and the grant Tacet needs for them and for the icon
/// order (MenuBarOrder, NOTES §22).
///
/// - Stored as `trackedApplications` in Control Center's group-container
///   preferences: a binary plist inside a Data value, an array of alternating
///   `{bundle: {_0: id}}` keys and `{isAllowed, location, menuItemLocations}`
///   values. A switch is the `isAllowed` flag.
/// - Access: one open panel where the user selects two folders,
///   `group.com.apple.controlcenter` and `com.apple.MenuBar`; Tacet keeps a
///   security-scoped bookmark for each. Without both it doesn't run.
/// - Reads and writes go through ContainerPrefs.
@MainActor
enum MenuBarSwitches {
    struct App: Equatable {
        let bundleID: String
        let isAllowed: Bool
    }

    enum Access: Equatable {
        case granted
        case notGranted     // never granted, or only one of the two folders
        case lost           // a bookmark exists but no longer works
    }

    static let prefs = ContainerPrefs.controlCenter
    static let key = "trackedApplications"
    /// System Settings › Menu Bar.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    static var isSupported: Bool { ContainerPrefs.isSupported }

    // MARK: Access

    /// The two folders the grant covers.
    static let containers = [ContainerPrefs.controlCenter, ContainerPrefs.menuBar]
    private static var scoped: [String: URL] = [:]
    private static func bookmarkKey(_ prefs: ContainerPrefs) -> String { "access.\(prefs.appID)" }

    /// Both folders granted and their files open.
    static func checkAccess() -> Access {
        var missing = false
        for prefs in containers {
            switch access(to: prefs) {
            case .granted: continue
            case .notGranted: missing = true
            case .lost: return .lost
            }
        }
        return missing ? .notGranted : .granted
    }

    /// Resolves the folder's bookmark (once per launch) and checks its
    /// preferences file opens.
    private static func access(to prefs: ContainerPrefs) -> Access {
        if scoped[prefs.appID] == nil {
            guard let data = UserDefaults.standard.data(forKey: bookmarkKey(prefs)) else { return .notGranted }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.standardizedFileURL.path == prefs.containerURL.standardizedFileURL.path,
                  url.startAccessingSecurityScopedResource() else {
                Log.write("Access: the saved access to \(prefs.appID) no longer resolves")
                return .lost
            }
            scoped[prefs.appID] = url
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey(prefs))
                Log.write("Access: refreshed a stale bookmark for \(prefs.appID)")
            }
        }
        guard prefs.canOpenFile() else {
            Log.write("Access: can't open \(prefs.plistURL.lastPathComponent)")
            scoped[prefs.appID]?.stopAccessingSecurityScopedResource()
            scoped[prefs.appID] = nil
            return .lost
        }
        return .granted
    }

    /// One open panel on ~/Library/Group Containers with everything greyed
    /// out but the folders still missing; the user ⌘-clicks both (NOTES
    /// §22). Returns the new access state.
    static func requestAccess() -> Access {
        let missing = containers.filter { access(to: $0) != .granted }
        guard !missing.isEmpty else { return .granted }
        let names = missing.map(\.appID)
        let panel = NSOpenPanel()
        let filter = OnlyFolders(missing.map(\.containerURL))
        panel.delegate = filter
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = missing[0].containerURL.deletingLastPathComponent()
        panel.message = names.count == 2
            ? String(localized: "Hold ⌘ and select “\(names[0])” and “\(names[1])”, then click Grant Access.")
            : String(localized: "Select “\(names[0])”, then click Grant Access.")
        panel.prompt = String(localized: "Grant Access")
        NSApp.activate()
        let response = panel.runModal()
        withExtendedLifetime(filter) {}
        guard response == .OK else { return checkAccess() }
        for url in panel.urls {
            guard let prefs = missing.first(where: { $0.containerURL.standardizedFileURL.path == url.standardizedFileURL.path }),
                  let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                Log.write("Access: couldn't keep \(url.lastPathComponent)")
                continue
            }
            UserDefaults.standard.set(data, forKey: bookmarkKey(prefs))
            scoped[prefs.appID]?.stopAccessingSecurityScopedResource()
            scoped[prefs.appID] = nil
        }
        let access = checkAccess()
        Log.write("Access: \(access) (picked \(panel.urls.count) of \(missing.count) folder(s))")
        if access == .granted {
            UserDefaults.standard.removeObject(forKey: "menuBarSettingsBookmark")   // the old file grant
        } else {
            let still = containers.filter { Self.access(to: $0) != .granted }.map(\.appID)
            let first = still.first ?? ""
            let alert = NSAlert()
            alert.messageText = String(localized: "Tacet needs both folders")
            alert.informativeText = still.count == 2
                ? String(localized: "Hold ⌘ and select “\(still[0])” and “\(still[1])”, then click Grant Access.")
                : String(localized: "Select “\(first)”, then click Grant Access.")
            alert.runModal()
        }
        return access
    }

    /// Greys out everything but the given folders and the folders on the
    /// way to them (an open panel can't hide items, only disable them).
    private final class OnlyFolders: NSObject, NSOpenSavePanelDelegate {
        let allowed: [String]
        init(_ urls: [URL]) { allowed = urls.map { $0.standardizedFileURL.path } }
        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return allowed.contains { $0 == path || $0.hasPrefix(path + "/") }
        }
    }

    // MARK: Reading

    /// The current switches, in macOS's order. Nil when they can't be read.
    static func read() -> [App]? {
        guard let list = decode(rawValue(), mutable: false) else { return nil }
        return list.compactMap { element in
            guard let entry = element as? NSDictionary,
                  let allowed = entry["isAllowed"] as? Bool,
                  let id = bundleID(of: entry) else { return nil }
            return App(bundleID: id, isAllowed: allowed)
        }
    }

    private static func rawValue() -> Data? { prefs.value(key) as? Data }

    private static func decode(_ data: Data?, mutable: Bool) -> NSArray? {
        guard let data else { return nil }
        let options: PropertyListSerialization.MutabilityOptions = mutable ? [.mutableContainersAndLeaves] : []
        return (try? PropertyListSerialization.propertyList(from: data, options: options, format: nil)) as? NSArray
    }

    private static func bundleID(of entry: NSDictionary) -> String? {
        ((entry["location"] as? NSDictionary)?["bundle"] as? NSDictionary)?["_0"] as? String
    }

    // MARK: Writing

    /// Sets `isAllowed` for the given apps in one write, on top of a fresh
    /// read.
    ///
    /// Read-modify-write of the whole value: a change MenuBarAgent or System
    /// Settings makes in the ~1 ms between the read and the write (a ⌘-drag,
    /// a newly tracked app) is lost. cfprefsd has no compare-and-swap, so this
    /// is accepted (review §4.2); the read-back below catches it when it hits
    /// `isAllowed`, and `ShelfModel.write` then follows a fresh read. Apps not in the list are skipped. Returns false if the write
    /// couldn't be made or didn't stick.
    @discardableResult
    static func setAllowed(_ changes: [String: Bool]) -> Bool {
        guard !changes.isEmpty else { return true }
        guard isSupported else { Log.write("Switches: CoreFoundation calls missing"); return false }
        guard let list = decode(rawValue(), mutable: true) as? NSMutableArray else {
            Log.write("Switches: can't read before writing"); return false
        }
        var changed: [String] = []
        for case let entry as NSMutableDictionary in list {
            guard let current = entry["isAllowed"] as? Bool,
                  let id = bundleID(of: entry),
                  let wanted = changes[id], wanted != current else { continue }
            entry["isAllowed"] = wanted
            changed.append("\(id)=\(wanted ? "on" : "off")")
        }
        guard !changed.isEmpty else { return true }
        guard let encoded = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else {
            Log.write("Switches: can't encode"); return false
        }
        let synced = prefs.set(key, encoded)
        // Read back: the write only counts if cfprefsd now holds it.
        let after = Dictionary((read() ?? []).map { ($0.bundleID, $0.isAllowed) }, uniquingKeysWith: { a, _ in a })
        let stuck = changes.allSatisfy { id, wanted in after[id].map { $0 == wanted } ?? true }
        Log.write("Switches: wrote \(changed.count) change(s) (synced \(synced), verified \(stuck))")
        Log.debug("Switches: wrote \(changed.sorted().joined(separator: ", "))")
        return stuck
    }
}
