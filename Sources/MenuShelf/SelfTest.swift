import AppKit

/// `MenuShelf --selftest`: exercises the VisibleCC hider against a throwaway
/// preferences domain (no real app is touched) and checks hide → restore
/// round-trips exactly. Needs no permissions.
@MainActor
enum SelfTest {
    static let domain = "dev.menushelf.selftest-target"

    static func run() {
        let d = domain as CFString
        func get(_ key: String) -> Bool? { CFPreferencesCopyAppValue(key as CFString, d) as? Bool }
        func set(_ key: String, _ value: Bool?) {
            CFPreferencesSetAppValue(key as CFString, value.map { $0 as CFBoolean as CFPropertyList }, d)
        }

        // Fake app with two status items: one with VisibleCC = true, one with no VisibleCC key.
        set("NSStatusItem Visible Item-0", true)
        set("NSStatusItem VisibleCC Item-0", true)
        set("NSStatusItem Preferred Position Item-1", true)
        CFPreferencesAppSynchronize(d)

        let fake = MenuBarApp(key: domain, pid: 1, name: "SelfTest", bundleID: domain, icon: nil, isSystem: false, items: [])
        let hider = VisibleCCHider()
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL")  \(label)")
            if !ok { failures += 1 }
        }

        check("autosave names found", VisibleCCHider.autosaveNames(for: domain) == ["Item-0", "Item-1"])
        check("supported", hider.unsupportedReason(for: fake) == nil)

        hider.apply(hiddenKeys: [domain], knownApps: [fake])
        CFPreferencesAppSynchronize(d)
        check("hide: Item-0 VisibleCC = false", get("NSStatusItem VisibleCC Item-0") == false)
        check("hide: Item-1 VisibleCC = false", get("NSStatusItem VisibleCC Item-1") == false)
        check("hide: marked for relaunch", hider.needsRelaunch.contains(domain))

        // Applying again must not overwrite the recorded originals.
        hider.apply(hiddenKeys: [domain], knownApps: [fake])

        hider.apply(hiddenKeys: [], knownApps: [fake])
        CFPreferencesAppSynchronize(d)
        check("restore: Item-0 back to true", get("NSStatusItem VisibleCC Item-0") == true)
        check("restore: Item-1 key removed again", get("NSStatusItem VisibleCC Item-1") == nil)
        check("restore: other keys untouched", get("NSStatusItem Visible Item-0") == true)

        // Clean up the throwaway domain.
        for key in CFPreferencesCopyKeyList(d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? [] {
            set(key, nil)
        }
        CFPreferencesAppSynchronize(d)
        print(failures == 0 ? "All self-tests passed" : "\(failures) self-test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
