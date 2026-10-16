import AppKit
import UniformTypeIdentifiers

/// The "Allow in the Menu Bar" switches of System Settings › Menu Bar
/// (NOTES §12–13).
///
/// - Stored as `trackedApplications` in Control Center's group-container
///   preferences: a binary plist inside a Data value, an array of alternating
///   `{bundle: {_0: id}}` keys and `{isAllowed, location, menuItemLocations}`
///   values. A switch is the `isAllowed` flag.
/// - Access: the user selects the plist once in an open panel; Tacet keeps
///   a security-scoped bookmark.
/// - Reads and writes go through CoreFoundation's container-aware preference
///   calls (private, looked up by name), so MenuBarAgent sees a write within
///   about a millisecond. The file on disk is flushed seconds later.
@MainActor
enum MenuBarSwitches {
    struct App: Equatable {
        let bundleID: String
        let isAllowed: Bool
    }

    enum Access: Equatable {
        case granted
        case notGranted     // never granted
        case lost           // a bookmark exists but no longer works
    }

    static let appID = "group.com.apple.controlcenter"
    static let key = "trackedApplications"
    static var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/\(appID)")
    }
    static var plistURL: URL { containerURL.appendingPathComponent("Library/Preferences/\(appID).plist") }
    /// System Settings › Menu Bar.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    private static let bookmarkKey = "menuBarSettingsBookmark"
    private static var scoped: URL?

    // CoreFoundation private, container-aware preferences (dlsym by name).
    private typealias CopyFn = @convention(c) (CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetFn = @convention(c) (CFString, CFPropertyList?, CFString, CFString) -> Void
    private typealias SyncFn = @convention(c) (CFString, CFString) -> DarwinBoolean
    private static let cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW)
    private static let copyValue = dlsym(cf, "_CFPreferencesCopyAppValueWithContainer").map { unsafeBitCast($0, to: CopyFn.self) }
    private static let setValue = dlsym(cf, "_CFPreferencesSetAppValueWithContainer").map { unsafeBitCast($0, to: SetFn.self) }
    private static let sync = dlsym(cf, "_CFPreferencesAppSynchronizeWithContainer").map { unsafeBitCast($0, to: SyncFn.self) }

    static var isSupported: Bool { copyValue != nil && setValue != nil && sync != nil }

    // MARK: Access

    /// Resolves the bookmark (once per launch) and checks the file opens.
    static func checkAccess() -> Access {
        if scoped == nil {
            guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return .notGranted }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.standardizedFileURL.path == plistURL.standardizedFileURL.path,
                  url.startAccessingSecurityScopedResource() else {
                Log.write("Switches: the saved access no longer resolves")
                return .lost
            }
            scoped = url
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                Log.write("Switches: refreshed a stale bookmark")
            }
        }
        guard canOpenFile() else {
            Log.write("Switches: can't open \(plistURL.lastPathComponent)")
            scoped?.stopAccessingSecurityScopedResource()
            scoped = nil
            return .lost
        }
        return .granted
    }

    /// Group containers are protected: opening the file fails with EPERM
    /// without the user's grant, even for a non-sandboxed app.
    private static func canOpenFile() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: plistURL) else { return false }
        try? handle.close()
        return true
    }

    /// Shows an open panel on the plist. Returns the new access state.
    static func requestAccess() -> Access {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        panel.directoryURL = plistURL.deletingLastPathComponent()
        panel.message = String(localized: "Select “\(plistURL.lastPathComponent)” and click Grant Access. It holds the “Allow in the Menu Bar” switches.")
        panel.prompt = String(localized: "Grant Access")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return checkAccess() }
        guard url.standardizedFileURL.path == plistURL.standardizedFileURL.path else {
            Log.write("Switches: picked \(url.lastPathComponent), not the Control Center file")
            let alert = NSAlert()
            alert.messageText = String(localized: "That’s a different file")
            alert.informativeText = String(localized: "Select “\(plistURL.lastPathComponent)” in the folder Tacet opens.")
            alert.runModal()
            return checkAccess()
        }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            Log.write("Switches: couldn't create a bookmark")
            return .lost
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        let access = checkAccess()
        Log.write("Switches: access \(access)")
        return access
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

    /// Fresh value from cfprefsd (synchronized first so another process's
    /// change isn't hidden by our cache); the file if that fails.
    private static func rawValue() -> Data? {
        if let copyValue, let sync {
            _ = sync(appID as CFString, containerURL.path as CFString)
            if let data = copyValue(key as CFString, appID as CFString, containerURL.path as CFString)?.takeRetainedValue() as? Data {
                return data
            }
        }
        return NSDictionary(contentsOf: plistURL)?[key] as? Data
    }

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
    /// read. Apps not in the list are skipped. Returns false if the write
    /// couldn't be made or didn't stick.
    @discardableResult
    static func setAllowed(_ changes: [String: Bool]) -> Bool {
        guard !changes.isEmpty else { return true }
        guard let setValue, let sync else { Log.write("Switches: CoreFoundation calls missing"); return false }
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
        setValue(key as CFString, encoded as CFData, appID as CFString, containerURL.path as CFString)
        let synced = sync(appID as CFString, containerURL.path as CFString).boolValue
        // Read back: the write only counts if cfprefsd now holds it.
        let after = Dictionary((read() ?? []).map { ($0.bundleID, $0.isAllowed) }, uniquingKeysWith: { a, _ in a })
        let stuck = changes.allSatisfy { id, wanted in after[id].map { $0 == wanted } ?? true }
        Log.write("Switches: wrote \(changed.sorted().joined(separator: ", ")) (synced \(synced), verified \(stuck))")
        return stuck
    }
}
