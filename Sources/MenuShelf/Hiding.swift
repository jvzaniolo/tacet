import AppKit

/// A way to make whole apps' menu bar items disappear and come back.
@MainActor
protocol AppHiding: AnyObject {
    var isOperational: Bool { get }
    var statusText: String { get }
    /// Make exactly `hiddenKeys` hidden; every other known app visible.
    func apply(hiddenKeys: Set<String>, knownApps: [MenuBarApp])
}

@MainActor
func makeHider() -> AppHiding {
    UnavailableHider()
}

/// Placeholder until the macOS 27 mechanism is wired up.
@MainActor
final class UnavailableHider: AppHiding {
    let isOperational = false
    let statusText = "Hiding is not implemented yet on this macOS version."
    func apply(hiddenKeys: Set<String>, knownApps: [MenuBarApp]) {
        Log.write("apply(hidden: \(hiddenKeys.sorted())) ignored: no hiding backend")
    }
}
