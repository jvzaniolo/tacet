import AppKit
import UniformTypeIdentifiers

/// Investigation (`--debug` only, NOTES §12): the System Settings › Menu Bar
/// "Allow in the Menu Bar" switches, stored as `trackedApplications` in
/// Control Center's group-container preferences.
///
/// Access: the user picks the one plist in an open panel; we keep a
/// security-scoped bookmark. Reads go through the file and through
/// CoreFoundation's container-aware preference calls (private, looked up by
/// name with dlsym). Writes only on an explicit `ccset` command.
@MainActor
enum ControlCenterSwitches {
    static let appID = "group.com.apple.controlcenter"
    static var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/\(appID)")
    }
    static var plistURL: URL { containerURL.appendingPathComponent("Library/Preferences/\(appID).plist") }
    private static let bookmarkKey = "ccSwitchesBookmark"
    private static var scoped: URL?

    // CoreFoundation private, container-aware preferences (dlsym by name).
    private typealias CopyFn = @convention(c) (CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetFn = @convention(c) (CFString, CFPropertyList?, CFString, CFString) -> Void
    private typealias SyncFn = @convention(c) (CFString, CFString) -> DarwinBoolean
    private static let cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW)
    private static let copyValue = dlsym(cf, "_CFPreferencesCopyAppValueWithContainer").map { unsafeBitCast($0, to: CopyFn.self) }
    private static let setValue = dlsym(cf, "_CFPreferencesSetAppValueWithContainer").map { unsafeBitCast($0, to: SetFn.self) }
    private static let sync = dlsym(cf, "_CFPreferencesAppSynchronizeWithContainer").map { unsafeBitCast($0, to: SyncFn.self) }

    // MARK: Access

    static func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        panel.directoryURL = plistURL.deletingLastPathComponent()
        panel.message = "MenuShelf test: select “\(appID).plist” to let MenuShelf read the “Allow in the Menu Bar” list."
        panel.prompt = "Grant Access"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { Log.write("CC: panel cancelled"); return }
        guard url.standardizedFileURL.path == plistURL.standardizedFileURL.path else {
            Log.write("CC: picked \(url.path), expected \(plistURL.path)"); return
        }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        activate()
        dump()
    }

    @discardableResult
    static func activate() -> Bool {
        if scoped != nil { return true }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return false }
        scoped = url
        return true
    }

    // MARK: Reading

    static func readFile() -> NSDictionary? {
        activate()
        return NSDictionary(contentsOf: plistURL)
    }

    static func readCF(_ key: String) -> Any? {
        activate()
        guard let copyValue else { return nil }
        return copyValue(key as CFString, appID as CFString, containerURL.path as CFString)?.takeRetainedValue()
    }

    static func dump() {
        guard let dict = readFile() else { Log.write("CC dump: can't read \(plistURL.path) (pick it first: ccpick)"); return }
        Log.write("CC dump: keys \((dict.allKeys as? [String])?.sorted() ?? [])")
        if let data = dict["trackedApplications"] as? Data {
            let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            Log.write("CC dump: trackedApplications decoded (\(decoded.map { "\(type(of: $0))" } ?? "undecodable")):\n\(decoded.map { "\($0)" } ?? "")")
        }
        Log.write("CC dump via CF: trackedApplications type \(readCF("trackedApplications").map { "\(type(of: $0))" } ?? "nil")")
    }

    // MARK: Watching (timing)

    private static var watchTimer: Timer?
    private static var lastFileStamp: String?
    private static var lastCF: String?

    /// Polls the file (mtime + content) and the CF value every 20 ms and logs
    /// each change with a millisecond timestamp.
    static func watch(_ on: Bool) {
        watchTimer?.invalidate()
        watchTimer = nil
        guard on else { Log.write("CC watch off"); return }
        activate()
        lastFileStamp = fileStamp()
        lastCF = readCF("trackedApplications").map { "\($0)" }
        Log.write("CC watch on")
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let stamp = fileStamp()
                if stamp != lastFileStamp { lastFileStamp = stamp; Log.write("CC watch: file changed (\(stamp ?? "nil"))") }
                let cfValue = readCF("trackedApplications").map { "\($0)" }
                if cfValue != lastCF { lastCF = cfValue; Log.write("CC watch: CF value changed") }
            }
        }
    }

    private static func fileStamp() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let size = attrs[.size] as? Int ?? 0
        return "\(date.timeIntervalSince1970) \(size)"
    }

    // MARK: Switching apps (explicit only)

    static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MenuShelf/debug/cc-trackedApplications.backup")
    }

    /// Sets `isAllowed` for the given bundle IDs in one write. The first
    /// call saves the original value to `backupURL` for `restore()`.
    static func setAllowed(_ allowed: Bool, for bundleIDs: Set<String>) {
        guard let dict = readFile(), let data = dict["trackedApplications"] as? Data else { Log.write("CC set: can't read"); return }
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? data.write(to: backupURL)
            Log.write("CC set: original saved to \(backupURL.path)")
        }
        guard let list = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: nil) as? NSMutableArray else {
            Log.write("CC set: can't decode"); return
        }
        var changed: [String] = []
        for case let entry as NSMutableDictionary in list {
            guard entry["isAllowed"] != nil,
                  let location = entry["location"] as? NSDictionary,
                  let bundle = (location["bundle"] as? NSDictionary)?["_0"] as? String,
                  bundleIDs.contains(bundle) else { continue }
            entry["isAllowed"] = allowed
            changed.append(bundle)
        }
        guard let encoded = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else {
            Log.write("CC set: can't encode"); return
        }
        Log.write("CC set: isAllowed=\(allowed) for \(changed.sorted())")
        write(key: "trackedApplications", value: encoded as CFData)
    }

    static func restore() {
        guard let data = try? Data(contentsOf: backupURL) else { Log.write("CC restore: no backup"); return }
        write(key: "trackedApplications", value: data as CFData)
        Log.write("CC restore: original written back")
    }

    // MARK: Writing (explicit only)

    /// Writes `value` (already in the stored format) under `key` and syncs.
    static func write(key: String, value: CFPropertyList) {
        activate()
        guard let setValue, let sync else { Log.write("CC write: CF functions missing"); return }
        Log.write("CC write: setting \(key)")
        setValue(key as CFString, value, appID as CFString, containerURL.path as CFString)
        let ok = sync(appID as CFString, containerURL.path as CFString).boolValue
        Log.write("CC write: synchronized \(ok)")
    }
}
