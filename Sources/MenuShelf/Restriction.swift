import AppKit

/// Keeps exactly one MenuBarAgent assertion alive and swaps it without a gap.
///
/// - A new assertion is activated before the old one is invalidated; while
///   both exist the newest wins, so nothing flashes in between.
/// - A failed activation keeps the previous one and is retried after 250 ms,
///   1 s and 4 s.
/// - While hiding, the allow-list follows the running apps (KVO on
///   `runningApplications`: launch notifications don't fire for LSUIElement
///   apps), so a newly launched app isn't hidden by accident.
@MainActor
final class Restriction {
    enum Mode: Equatable {
        case off                    // no assertion: MenuBarAgent shows everything
        case hiding(Set<String>)    // allow everything except these bundle IDs
        case showingAll             // allow everything (keeps an assertion alive)
    }

    private(set) var mode: Mode = .off
    private var current: MenuBarAssertion?
    private var pending: MenuBarAssertion?
    private var retry = 0
    private var runningObservation: NSKeyValueObservation?
    var onApplied: ((Mode, TimeInterval) -> Void)?

    static var isAvailable: Bool { MenuBarAssertionAPI.isAvailable }

    init() {
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.runningAppsChanged() }
        }
    }

    /// Every bundle ID that could own a menu bar item right now.
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func allowList(for mode: Mode) -> Set<String>? {
        let own = Bundle.main.bundleIdentifier ?? "dev.menushelf.MenuShelf"
        switch mode {
        case .off: return nil
        case .showingAll: return Self.runningBundleIDs().union([own])
        case .hiding(let hidden): return Self.runningBundleIDs().subtracting(hidden).union([own])
        }
    }

    /// MenuBarAgent finishes a running hide/show animation (~0.5 s) before it
    /// takes the next allow-list, so rapid toggles stalled the bar. Changes
    /// within this window of the last one are merged: only the final state
    /// is sent, once the window ends (nothing at all if it's unchanged).
    static let minimumInterval: TimeInterval = 0.35
    private var lastSent = Date.distantPast
    private var deferredApply = false

    func set(_ mode: Mode) {
        self.mode = mode
        retry = 0
        let wait = Self.minimumInterval - Date().timeIntervalSince(lastSent)
        guard wait > 0 else { apply(); return }
        guard !deferredApply else { return }
        deferredApply = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.deferredApply = false
            self?.apply()
        }
    }

    private func apply() {
        guard let allowed = allowList(for: mode) else {
            pending?.invalidate(); pending = nil
            current?.invalidate(); current = nil
            onApplied?(.off, 0)
            return
        }
        // Same allow-list already held: nothing to do.
        if let current, current.allowedBundleIDs == allowed, pending == nil { return }
        guard let assertion = MenuBarAssertion(allowing: allowed) else {
            Log.write("Restriction: MBAssessmentModeAssertion unavailable")
            return
        }
        pending?.invalidate()
        pending = assertion
        lastSent = Date()
        let started = Date()
        let mode = self.mode
        assertion.activate { [weak self] a, b in
            DispatchQueue.main.async {
                self?.activated(assertion, mode: mode, rawA: a, rawB: b, started: started)
            }
        }
    }

    private func activated(_ assertion: MenuBarAssertion, mode: Mode, rawA: UInt, rawB: UInt, started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        // Observed on 27.0.1: the block's first argument is an NSError pointer
        // (0 = success); the second raw value is leftover register content
        // (e.g. 3) and is ignored (NOTES §11).
        let ok = rawA == 0
        Log.write("Restriction \(Self.describe(mode)) activated in \(Int(elapsed * 1000)) ms (raw \(rawA), \(rawB))\(ok ? "" : " — treating as failure")")
        guard assertion === pending else { return }   // superseded
        guard ok else {
            pending = nil
            assertion.invalidate()
            let delays: [TimeInterval] = [0.25, 1, 4]
            guard retry < delays.count else { return }
            let delay = delays[retry]
            retry += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            return
        }
        // Only now drop the old one: the new one is already in force.
        current?.invalidate()
        current = assertion
        pending = nil
        onApplied?(mode, elapsed)
    }

    private func runningAppsChanged() {
        guard mode != .off else { return }
        apply()
    }

    /// Ends all restriction (quit).
    func releaseAll() {
        mode = .off
        pending?.invalidate(); pending = nil
        current?.invalidate(); current = nil
    }

    static func describe(_ mode: Mode) -> String {
        switch mode {
        case .off: return "off"
        case .showingAll: return "show-all"
        case .hiding(let hidden): return "hide[\(hidden.sorted().joined(separator: ","))]"
        }
    }
}
