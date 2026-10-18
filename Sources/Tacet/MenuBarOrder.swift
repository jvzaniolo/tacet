import AppKit

/// The order of the menu bar icons: `TrailingItemPreferredPositions` in
/// MenuBar's group container, the table MenuBarAgent writes when the user
/// ⌘-drags an icon (NOTES §22).
///
/// - Keys: `status:<owner>::<autosave name>` per status item (the owner is
///   the bundle ID for an app in /Applications, else the executable's name),
///   `module:<name>` for Apple's. An app can have several.
/// - Values: weights; larger is further left. Only the order of the items
///   on screen matters. MenuBarAgent never removes keys and merges its own
///   writes with ours.
/// - A weight written while an item is hidden is where it comes back; one
///   written while it's on screen moves it live (~1 s slide).
///
/// Tacet keeps `[always hidden] [hidden] « [visible]`: the arrow left of
/// every other icon, the hidden apps left of it, the always-hidden ones
/// further left. Within each group the user's order is kept.
@MainActor
enum MenuBarOrder {
    static let prefs = ContainerPrefs.menuBar
    static let key = "TrailingItemPreferredPositions"
    /// Set once the first arrangement (the arrow left of everything) is done.
    private static let arrangedKey = "order.arranged.v1"
    private static let ownID = Bundle.main.bundleIdentifier ?? "app.gettacet.Tacet"

    /// A copy of the table from before Tacet first wrote it.
    static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tacet/menubar-order-backup.plist")
    }

    enum Group { case visible, hidden, alwaysHidden }

    // MARK: Reading

    static func positions() -> [String: Double]? {
        guard let raw = prefs.value(key) as? [String: Any] else {
            Log.write("Order: can't read the table")
            return nil
        }
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// The arrow's key. MenuBarAgent names a status item's owner by its
    /// bundle ID for an app in /Applications and by its executable name
    /// elsewhere (a build folder). Only that key is read and written: the
    /// other form, if present, is a leftover and must not count.
    private static var arrowKey: String {
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
        let owner = installed ? ownID : (Bundle.main.executableURL?.lastPathComponent ?? "Tacet")
        return "status:\(owner)::TacetArrow"
    }

    private static var executables: [String: Set<String>] = [:]

    /// The table keys of an app's status items (none until one has shown).
    /// The owner is matched against every executable registered for the
    /// bundle ID and the running ones: an app can ship a nested helper
    /// with the same ID (Riot Client's is found first, but its status item
    /// belongs to the outer app's RiotClientServices).
    static func keys(of id: String, in table: [String: Double]) -> [String] {
        if executables[id] == nil {
            executables[id] = Set(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
                .compactMap { Bundle(url: $0)?.executableURL?.lastPathComponent })
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .compactMap { $0.executableURL?.lastPathComponent }
        let owners = executables[id, default: []].union(running).union([id])
        let prefixes = owners.map { "status:\($0)::" }
        return table.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
    }

    static func hasKeys(_ id: String) -> Bool {
        positions().map { !keys(of: id, in: $0).isEmpty } ?? false
    }

    // MARK: Arranging

    /// Brings the table in line with the fixed order, in one write.
    ///
    /// Only the relative order counts: MenuBarAgent renumbers the icons
    /// around a ⌘-drag (to round weights like 400, 368, 336…), so the
    /// arrow's weight is read from the table each time, never remembered.
    ///
    /// - `visible`: the tracked apps not hidden by Tacet. Their keys and
    ///   Apple's `module:` keys are the visible icons; keys of other owners
    ///   are left over from apps long gone and are ignored.
    /// - `moved`: apps that just changed group (their switch is off): put at
    ///   the arrow-side edge of their group, or right next to the arrow for
    ///   `.visible`.
    /// - `hiddenOnScreen`: the hidden apps are revealed, so their weights
    ///   aren't touched (a correction would slide them in view) except for
    ///   `moved` ones; the rest waits for the next conceal.
    ///
    /// Returns false if the table can't be read or the write didn't stick.
    @discardableResult
    static func arrange(visible: Set<String>, alwaysHidden: Set<String>, hidden: Set<String>,
                        moved: [String: Group] = [:], hiddenOnScreen: Bool) -> Bool {
        guard let table = positions() else { return false }
        backUpOnce(table)
        logOutsideChanges(table)

        func weight(_ key: String) -> Double { table[key] ?? 0 }
        func keys(_ ids: Set<String>) -> [String] { ids.flatMap { Self.keys(of: $0, in: table) } }
        let alwaysKeys = keys(alwaysHidden)
        let hiddenKeys = keys(hidden)
        let movedKeys: [String: Group] = moved.reduce(into: [:]) { result, move in
            for key in Self.keys(of: move.key, in: table) { result[key] = move.value }
        }
        let visibleKeys = keys(visible) + table.keys.filter { $0.hasPrefix("module:") }
        let settled = visibleKeys.filter { movedKeys[$0] == nil }
        var changes: [String: Double] = [:]

        // The arrow. The first time, left of every visible icon.
        let maxVisible = settled.map(weight).max() ?? 0
        var arrow = table[arrowKey] ?? 0
        if !UserDefaults.standard.bool(forKey: arrangedKey) {
            if arrow <= maxVisible { arrow = maxVisible.rounded(.down) + 1 }
            UserDefaults.standard.set(true, forKey: arrangedKey)
            Log.write("Order: first arrangement, the arrow left of every visible icon")
        }

        // Visible icons left of the arrow (a drag, a new item): either the
        // arrow goes back left of them or they go back right of it,
        // whichever moves fewer icons on screen.
        let strays = settled.filter { weight($0) >= arrow }
        if !strays.isEmpty {
            let newArrow = maxVisible + 1
            let shownHidden = hiddenOnScreen ? hiddenKeys.filter { weight($0) <= newArrow }.count : 0
            if 1 + shownHidden < strays.count {
                Log.write("Order: the arrow was moved; putting it back left of the visible icons")
                arrow = newArrow
            }
        }
        if table[arrowKey] != arrow { changes[arrowKey] = arrow }

        // Visible icons still left of the arrow, and apps moved back to
        // visible: right next to it, in their order, the moved ones closest.
        // Listed right to left.
        let right = visibleKeys.filter { weight($0) >= arrow || movedKeys[$0] == .visible }
            .sorted { (movedKeys[$0] == .visible ? 1 : 0, weight($0)) < (movedKeys[$1] == .visible ? 1 : 0, weight($1)) }
        if !right.isEmpty {
            let below = settled.filter { weight($0) < arrow }.map(weight).max() ?? (arrow - 1)
            let step = (arrow - below) / Double(right.count + 1)
            for (i, key) in right.enumerated() { changes[key] = below + step * Double(i + 1) }
        }

        if hiddenOnScreen {
            // Only the moved apps, slotted in without touching the others:
            // between their neighbours, an app's items in their order.
            let stay = { (keys: [String]) in keys.filter { movedKeys[$0] == nil }.map(weight).filter { $0 > arrow } }
            let hiddenTop = (stay(hiddenKeys) + [arrow]).max() ?? arrow
            for group in [Group.hidden, .alwaysHidden] {
                let keys = movedKeys.filter { $0.value == group }.map(\.key).sorted { weight($0) < weight($1) }
                guard !keys.isEmpty else { continue }
                let low = group == .hidden ? arrow : hiddenTop
                let high = (group == .hidden ? stay(hiddenKeys) : stay(alwaysKeys).filter { $0 > hiddenTop }).min() ?? low + 1
                for (i, key) in keys.enumerated() {
                    changes[key] = low + (high - low) * Double(i + 1) / Double(keys.count + 1)
                }
            }
        } else {
            // Both groups are off screen: lay them out again if anything is
            // out of place, keeping each group's order (moved ones at the
            // arrow-side edge).
            func ordered(_ keys: [String]) -> [String] {
                keys.sorted { (movedKeys[$0] != nil ? 1 : 0, -weight($0)) < (movedKeys[$1] != nil ? 1 : 0, -weight($1)) }
            }
            let lowestAlways = alwaysKeys.map(weight).min() ?? .infinity
            let highestHidden = hiddenKeys.map(weight).max() ?? arrow
            let outOfPlace = hiddenKeys.contains { weight($0) <= arrow }
                || alwaysKeys.contains { weight($0) <= arrow }
                || lowestAlways <= highestHidden
                || movedKeys.values.contains { $0 != .visible }
                || changes[arrowKey] != nil
            if outOfPlace {
                // Left to right: always hidden, then hidden, then the arrow.
                let layout = ordered(alwaysKeys) + ordered(hiddenKeys)
                for (i, key) in layout.enumerated() {
                    let wanted = arrow + Double(layout.count - i)
                    if table[key] != wanted { changes[key] = wanted }
                }
            }
        }

        return write(changes, over: table)
    }

    /// Merges the changes into a fresh read and writes the whole table
    /// once, then reads it back; one retry if MenuBarAgent wrote in between.
    private static func write(_ changes: [String: Double], over table: [String: Double]) -> Bool {
        guard !changes.isEmpty else { return true }
        for attempt in 1...2 {
            guard var raw = prefs.value(key) as? [String: Any] else {
                Log.write("Order: can't read before writing")
                return false
            }
            for (key, value) in changes { raw[key] = NSNumber(value: value) }
            let synced = prefs.set(key, raw as NSDictionary)
            let after = positions() ?? [:]
            let stuck = changes.allSatisfy { after[$0.key] == $0.value }
            Log.write("Order: wrote \(changes.count) position(s) (synced \(synced), verified \(stuck))\(attempt > 1 ? " on retry" : "")")
            Log.debug("Order: wrote " + changes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            if stuck {
                lastSeen = after
                return true
            }
        }
        return false
    }

    /// The table as Tacet last saw or wrote it, to log what others changed.
    private static var lastSeen: [String: Double]?

    private static func logOutsideChanges(_ table: [String: Double]) {
        defer { lastSeen = table }
        guard Log.isDebug, let lastSeen else { return }
        let changed = table.filter { lastSeen[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        Log.debug("Order: changed by others: " + changed.sorted { $0.value > $1.value }
            .map { "\($0.key)=\(lastSeen[$0.key].map { "\($0)" } ?? "new")→\($0.value)" }.joined(separator: ", "))
    }

    // MARK: Backup

    private static var backedUp = false

    /// Keeps the table as it was before Tacet's first write, once.
    private static func backUpOnce(_ table: [String: Double]) {
        guard !backedUp else { return }
        backedUp = true
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ok = (table as NSDictionary).write(to: backupURL, atomically: true)
        Log.write("Order: backed up the table (\(table.count) keys, \(ok ? "ok" : "failed"))")
    }

    /// `--restore-order-backup`: writes the backup back and forgets the
    /// arrow's weight. For testing and recovery.
    static func restoreBackup() {
        guard let backup = NSDictionary(contentsOf: backupURL) as? [String: Any] else {
            Log.write("Order: no backup to restore")
            return
        }
        prefs.set(key, backup as NSDictionary)
        UserDefaults.standard.removeObject(forKey: arrangedKey)
        Log.write("Order: restored the backup (\(backup.count) keys)")
    }

    /// `--reset-order`: removes the arrow's keys and its saved weight, as on
    /// a first install. For testing.
    static func resetArrow() {
        guard var raw = prefs.value(key) as? [String: Any] else { return }
        raw[arrowKey] = nil
        prefs.set(key, raw as NSDictionary)
        UserDefaults.standard.removeObject(forKey: arrangedKey)
        Log.write("Order: reset the arrow's position")
    }

    // MARK: Watching

    private static var watcher: DispatchSourceFileSystemObject?

    /// Calls `onChange` when the table's folder changes (MenuBarAgent saves
    /// after a ⌘-drag or a new item; our own writes land there too, and
    /// `arrange` then finds nothing to do).
    static func watch(_ onChange: @escaping @MainActor () -> Void) {
        guard watcher == nil else { return }
        let folder = prefs.plistURL.deletingLastPathComponent().path
        let fd = open(folder, O_EVTONLY)
        guard fd >= 0 else {
            Log.write("Order: can't watch the table (\(errno)); checking on show and hide only")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.debug("Order: the table's folder changed")
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        Log.write("Order: watching the table")
    }
}
