import AppKit
import Observation

/// What Tacet hides and what it has switched off (NOTES §13).
///
/// Three states per app in `trackedApplications`:
/// - Visible: not in `hidden`, switch on. Tacet leaves it alone.
/// - Hidden: in `hidden`. Switch off while concealed, on while revealed.
/// - Off in System Settings: not in `hidden`, switch off. The user turned it
///   off in macOS; Tacet never turns it on.
///
/// The journal (`heldOff`) is the set of apps whose switch Tacet has
/// turned off. It is saved before every write that turns one off, so after a
/// crash the next launch knows which "off" switches are Tacet's.
@MainActor
@Observable
final class ShelfModel {
    enum Status { case visible, hidden, offInSystemSettings }

    struct Row: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage
        let status: Status
        var id: String { bundleID }
    }

    private(set) var access: MenuBarSwitches.Access = .notGranted
    private(set) var rows: [Row] = []
    private(set) var revealed = false
    /// Beta build past its expiry: hide nothing, restore what was hidden.
    private(set) var expired = false
    private(set) var lastError: String?

    private static let ownID = Bundle.main.bundleIdentifier ?? "app.gettacet.Tacet"
    private static let hiddenKey = "hiddenApps.v3"

    /// The user's choice: apps hidden behind «.
    private(set) var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden).sorted(), forKey: Self.hiddenKey) }
    }
    private(set) var heldOff: Set<String>
    private var switches: [String: Bool] = [:]
    @ObservationIgnored private var appInfo: [String: (name: String, icon: NSImage)] = [:]

    init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        heldOff = Journal.load()
    }

    var hasHiddenApps: Bool { !hidden.isEmpty }

    // MARK: Launch and quit

    /// Called once at launch, before anything is written.
    func start() {
        access = MenuBarSwitches.checkAccess()
        guard access == .granted, let current = readSwitches() else {
            if !heldOff.isEmpty {
                Log.write("Launch: \(heldOff.count) app(s) may still be off from the last run, but the switches can't be read (\(access))")
            }
            return
        }
        Log.write("Launch: switches " + current.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value ? "on" : "off")" }.joined(separator: ", ")
                  + "; hidden \(hidden.sorted()); held off \(heldOff.sorted())")
        if !heldOff.isEmpty {
            // The last run didn't restore on quit (crash, kill -9, power loss).
            // Switches still off are adopted: they're concealed, which is
            // where we start. Switches someone turned back on are dropped
            // from the journal; their apps stay hidden and conceal() hides
            // them again. Anything held off but no longer hidden is restored.
            let stillOff = heldOff.filter { current[$0] == false }
            let orphaned = stillOff.subtracting(hidden)
            Log.write("Launch: recovering from the last run; held off \(heldOff.sorted()), still off \(stillOff.sorted())")
            heldOff = stillOff
            Journal.save(heldOff)
            if !orphaned.isEmpty { write(Dictionary(uniqueKeysWithValues: orphaned.map { ($0, true) })) }
        }
        reconcile(current)
    }

    /// Turns every app Tacet switched off back on (Quit).
    @discardableResult
    func restoreAll() -> Bool {
        guard !heldOff.isEmpty else { return true }
        guard access == .granted else {
            Log.write("Restore: no access; \(heldOff.sorted()) stay off")
            return false
        }
        return write(Dictionary(uniqueKeysWithValues: heldOff.map { ($0, true) }))
    }

    // MARK: Access

    func requestAccess() {
        access = MenuBarSwitches.requestAccess()
        // Brings switches in line (e.g. hides again after access was lost).
        if access == .granted { apply() } else { rows = [] }
    }

    // MARK: Reading

    /// Re-reads the switches and folds in changes made in System Settings.
    func refresh() {
        guard access == .granted else { rows = []; return }
        guard let current = readSwitches() else {
            access = MenuBarSwitches.checkAccess()
            return
        }
        reconcile(current)
    }

    private func readSwitches() -> [String: Bool]? {
        guard let apps = MenuBarSwitches.read() else {
            Log.write("Switches: can't read")
            return nil
        }
        return Dictionary(apps.filter { $0.bundleID != Self.ownID }.map { ($0.bundleID, $0.isAllowed) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Respect what the user did in System Settings:
    /// - An app Tacet held off that is now on was turned on by the user:
    ///   it becomes Visible.
    /// - A hidden app that is off although Tacet didn't turn it off was
    ///   turned off by the user: it becomes Off in System Settings.
    private func reconcile(_ current: [String: Bool]) {
        switches = current
        var changed = false
        for id in heldOff where current[id] != false {
            heldOff.remove(id)
            changed = true
            if current[id] == true, hidden.remove(id) != nil {
                Log.write("Reconcile: \(id) was turned on in System Settings; now Visible")
            }
        }
        for id in hidden where current[id] == false && !heldOff.contains(id) {
            hidden.remove(id)
            Log.write("Reconcile: \(id) was turned off in System Settings; Tacet won't turn it on")
        }
        if changed { Journal.save(heldOff) }
        rebuildRows()
    }

    private func rebuildRows() {
        rows = switches.keys.map { id in
            let info = info(for: id)
            let status: Status = hidden.contains(id) ? .hidden : (switches[id] == true ? .visible : .offInSystemSettings)
            return Row(bundleID: id, name: info.name, icon: info.icon, status: status)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func info(for id: String) -> (name: String, icon: NSImage) {
        if let cached = appInfo[id] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        appInfo[id] = (name, icon)
        return (name, icon)
    }

    // MARK: Changing

    /// From the Settings list. Takes effect at once while concealed.
    func setHidden(_ id: String, _ hide: Bool) {
        guard id != Self.ownID else { return }
        if hide { hidden.insert(id) } else { hidden.remove(id) }
        apply()
    }

    func conceal() { revealed = false; apply() }

    /// The beta has ended: turn every switch Tacet changed back on, for good.
    func expire() {
        expired = true
        revealed = false
        Log.write("Beta expired: restoring and no longer hiding")
        restoreAll()
    }
    func reveal() { revealed = true; apply() }

    /// Brings the switches in line with `hidden` and `revealed`, in one write.
    private func apply() {
        guard !expired else { restoreAll(); return }
        guard access == .granted, let current = readSwitches() else { rebuildRows(); return }
        reconcile(current)
        var changes: [String: Bool] = [:]
        if !revealed {
            for id in hidden where current[id] == true { changes[id] = false }
        }
        for id in heldOff where revealed || !hidden.contains(id) { changes[id] = true }
        write(changes)
    }

    /// One write. The journal gets the apps being turned off before the
    /// write, and loses the ones turned on only after it.
    @discardableResult
    private func write(_ changes: [String: Bool]) -> Bool {
        guard !changes.isEmpty else { rebuildRows(); return true }
        let offs = Set(changes.filter { !$0.value }.keys)
        let ons = Set(changes.filter { $0.value }.keys)
        if !offs.isEmpty {
            heldOff.formUnion(offs)
            Journal.save(heldOff)
        }
        let ok = MenuBarSwitches.setAllowed(changes)
        if ok {
            heldOff.subtract(ons)
            lastError = nil
        } else {
            // Nothing changed: undo the journal entries this write added.
            heldOff.subtract(offs.filter { switches[$0] == true })
            lastError = String(localized: "Tacet couldn’t change the menu bar switches.")
        }
        Journal.save(heldOff)
        for (id, value) in changes where ok { switches[id] = value }
        rebuildRows()
        return ok
    }
}

/// `~/Library/Application Support/Tacet/journal.plist`: the apps whose
/// switch Tacet turned off. Written atomically before each such write.
enum Journal {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tacet/journal.plist")
    }

    static func load() -> Set<String> {
        guard let dict = NSDictionary(contentsOf: url), let ids = dict["heldOff"] as? [String] else { return [] }
        return Set(ids)
    }

    static func save(_ ids: Set<String>) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict: NSDictionary = ["heldOff": ids.sorted(), "updated": Date()]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return }
        do { try data.write(to: url, options: .atomic) } catch { Log.write("Journal: can't save (\(error.localizedDescription))") }
    }
}
