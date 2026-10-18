import Foundation

/// A preferences domain inside a protected group container, read and written
/// through CoreFoundation's container-aware calls (private, looked up by
/// name), so the owning agent sees a write within about a millisecond. The
/// file on disk is flushed seconds later.
///
/// Two are used: Control Center's (the "Allow in the Menu Bar" switches,
/// MenuBarSwitches) and MenuBar's (the order of the icons, MenuBarOrder).
/// Both need the user's grant (MenuBarSwitches.requestAccess).
struct ContainerPrefs {
    let appID: String

    var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/\(appID)")
    }
    var plistURL: URL { containerURL.appendingPathComponent("Library/Preferences/\(appID).plist") }

    static let controlCenter = ContainerPrefs(appID: "group.com.apple.controlcenter")
    static let menuBar = ContainerPrefs(appID: "com.apple.MenuBar")

    private typealias CopyFn = @convention(c) (CFString, CFString, CFString) -> Unmanaged<CFPropertyList>?
    private typealias SetFn = @convention(c) (CFString, CFPropertyList?, CFString, CFString) -> Void
    private typealias SyncFn = @convention(c) (CFString, CFString) -> DarwinBoolean
    private static let cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW)
    private static let copyFn = dlsym(cf, "_CFPreferencesCopyAppValueWithContainer").map { unsafeBitCast($0, to: CopyFn.self) }
    private static let setFn = dlsym(cf, "_CFPreferencesSetAppValueWithContainer").map { unsafeBitCast($0, to: SetFn.self) }
    private static let syncFn = dlsym(cf, "_CFPreferencesAppSynchronizeWithContainer").map { unsafeBitCast($0, to: SyncFn.self) }

    static var isSupported: Bool { copyFn != nil && setFn != nil && syncFn != nil }

    /// Fresh value from cfprefsd (synchronized first so another process's
    /// change isn't hidden by our cache); the file if that fails.
    func value(_ key: String) -> Any? {
        if let copyFn = Self.copyFn {
            synchronize()
            if let value = copyFn(key as CFString, appID as CFString, containerURL.path as CFString)?.takeRetainedValue() {
                return value
            }
        }
        return NSDictionary(contentsOf: plistURL)?[key]
    }

    /// Sets the value and synchronizes; false if the calls are missing or
    /// the sync failed (the caller reads back to be sure).
    @discardableResult
    func set(_ key: String, _ value: Any) -> Bool {
        guard let setFn = Self.setFn else { return false }
        setFn(key as CFString, value as CFPropertyList, appID as CFString, containerURL.path as CFString)
        return synchronize()
    }

    @discardableResult
    func synchronize() -> Bool {
        Self.syncFn?(appID as CFString, containerURL.path as CFString).boolValue ?? false
    }

    /// Group containers are protected: opening the file fails with EPERM
    /// without the user's grant, even for a non-sandboxed app.
    func canOpenFile() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: plistURL) else { return false }
        try? handle.close()
        return true
    }
}
