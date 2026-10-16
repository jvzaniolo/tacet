import AppKit
import SwiftUI

/// The one Tacet window: the welcome and access step until the user has
/// granted access, then the list of apps (in the style of System Settings ›
/// Menu Bar › Allow in the Menu Bar).
@MainActor
final class SettingsWindowController {
    private let model: ShelfModel
    private let ui = SettingsUIState()
    private var window: NSWindow?
    private var timer: Timer?

    init(model: ShelfModel) {
        self.model = model
    }

    var needsWelcome: Bool { model.access != .granted || !ui.didOnboard }

    func show() {
        model.refresh()
        ui.animationStart = .now
        ui.animationRuns = 2
        if window == nil {
            let view = SettingsRoot(model: model, ui: ui)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Tacet"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.timer?.invalidate()
                    self?.timer = nil
                }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // There's no change notification for these switches: while the
        // window is open, re-read them so changes made in System Settings
        // and newly tracked apps show up.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }
}

@MainActor
@Observable
final class SettingsUIState {
    private static let key = "didOnboard.v3"
    /// The arrow animation plays twice when the window opens, then waits
    /// for the play button (one run per click).
    var animationStart: Date?
    var animationRuns = 2

    var didOnboard = UserDefaults.standard.bool(forKey: key) {
        didSet { UserDefaults.standard.set(didOnboard, forKey: Self.key) }
    }
}

private struct SettingsRoot: View {
    let model: ShelfModel
    let ui: SettingsUIState

    var body: some View {
        Group {
            if model.access == .granted && ui.didOnboard {
                AppListView(model: model, ui: ui)
            } else {
                WelcomeView(model: model, ui: ui)
            }
        }
        .frame(width: 480)
    }
}

// MARK: Welcome and access

private struct WelcomeView: View {
    let model: ShelfModel
    let ui: SettingsUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Tacet").font(.title2.bold())
            Point(icon: "switch.2", title: "Tacet uses the macOS switches",
                  text: "It hides apps with the “Allow in the Menu Bar” switches in System Settings › Menu Bar. macOS does the hiding, so Notification Center, Focus and the camera and microphone indicators keep working.")
            Point(icon: "eye.slash", title: "Hidden apps show as off in System Settings",
                  text: "Click « in the menu bar to bring them back. If anything ever goes wrong, turn them back on in System Settings › Menu Bar.")
            Point(icon: "arrow.uturn.backward", title: "Quitting turns them back on",
                  text: "Quitting Tacet turns every app it hid back on. Quit Tacet before you delete it.")

            Divider()

            if !MenuBarSwitches.isSupported {
                Label("This version of macOS doesn’t offer the switches Tacet needs.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.access == .granted {
                Label("Tacet can change the switches.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow Tacet to change the switches").font(.headline)
                    if model.access == .lost {
                        Text("Tacet lost access to the switches. Apps it hid may still be off: grant access again and Tacet turns them back on when you quit it, or turn them on yourself in System Settings › Menu Bar.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("macOS keeps the switches in a Control Center settings file. In the next window, select “\(MenuBarSwitches.plistURL.lastPathComponent)” (Tacet opens its folder) and click Grant Access. Tacet changes only the “Allow in the Menu Bar” switches in it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                if model.access == .granted {
                    Button("Choose Apps to Hide…") { ui.didOnboard = true }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Grant Access…") { model.requestAccess() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!MenuBarSwitches.isSupported)
                }
            }
        }
        .padding(24)
    }
}

private struct Point: View {
    let icon: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: The list

private struct AppListView: View {
    let model: ShelfModel
    let ui: SettingsUIState

    private var managed: [ShelfModel.Row] { model.rows.filter { $0.status != .offInSystemSettings } }
    private var offInSettings: [ShelfModel.Row] { model.rows.filter { $0.status == .offInSystemSettings } }

    var body: some View {
        Form {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if model.hasHiddenApps {
                ArrowPlacementSection(ui: ui)
            }

            Section {
                if managed.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach(managed) { row in
                    AppRow(row: row) {
                        Toggle("Hide \(row.name) in Tacet", isOn: Binding(
                            get: { row.status == .hidden },
                            set: { model.setHidden(row.bundleID, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide in Tacet")
                    Text("Apps turned on here hide behind Tacet’s arrow. Click « in the menu bar to show them.")
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            } footer: {
                Text("Apps appear here after their first time in the menu bar.")
                    .foregroundStyle(.secondary)
            }

            if !offInSettings.isEmpty {
                Section {
                    ForEach(offInSettings) { row in
                        AppRow(row: row) {
                            Text("Off").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Turned Off in System Settings")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hidden by macOS, not by Tacet: « doesn’t show them. Turn them on in System Settings to use them.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Menu Bar Settings…") { NSWorkspace.shared.open(MenuBarSwitches.settingsURL) }
                    }
                }
            }

            Section {
                Text("Tip: ⌘-drag your hidden apps to the left end of the menu bar. Then they fade in and out quickly; elsewhere the icons next to them slide over.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}

private struct AppRow<Accessory: View>: View {
    let row: ShelfModel.Row
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: row.icon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(row.name)
            Spacer()
            accessory()
        }
    }
}

// MARK: Arrow position

/// How to put the arrow right of the hidden apps (NOTES §15). On first launch
/// macOS puts a new item at the far left, and only a ⌘-drag moves it.
private struct ArrowPlacementSection: View {
    let ui: SettingsUIState

    var body: some View {
        Section {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    DragAnimation(start: ui.animationStart, runs: ui.animationRuns) { finished in
                        // Back to the static final frame, so the timeline stops.
                        if ui.animationStart == finished { ui.animationStart = nil }
                    }
                    Button {
                        ui.animationRuns = 1
                        ui.animationStart = .now
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.borderless)
                    .disabled(ui.animationStart != nil)   // playing
                    .help(Text("Play Animation"))
                    .accessibilityLabel(Text("Play Animation"))
                    .padding(.top, 6)
                }
                Text("Hold ⌘ and drag the » arrow to the right of the apps you hide.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } header: {
            Text("Arrow Position")
        }
    }
}

/// A looping sketch of the ⌘-drag on a mini menu bar: the pointer grabs the
/// arrow, which sits left of three app icons, and drops it to their right.
/// Neutral template glyphs and system colors, so it reads as a menu bar in
/// light and dark mode.
///
/// Driven by a 30 fps timeline from the clock, not a phase animator: every
/// frame is a pure function of the time, so it can't loop on itself (a
/// PhaseAnimator version spun the main thread at 100 %, NOTES §15).
struct DragAnimation: View {
    /// When the current playback began; nil = show the final frame.
    let start: Date?
    let runs: Int
    /// Called with `start` once the last run ends.
    var onFinished: (Date) -> Void = { _ in }

    private static let slot: CGFloat = 26
    private static let glyphs = ["circle.hexagongrid.fill", "bolt.horizontal.circle", "cloud.fill"]
    private static let cycle: Double = 4.0
    private var appsWidth: CGFloat { CGFloat(Self.glyphs.count) * Self.slot }

    /// The parts of the cycle where something moves; the rest is still, so
    /// the timeline only redraws at its edges.
    private static let moving: [ClosedRange<Double>] = [0.8...1.2, 1.6...2.6, 3.0...3.4]

    /// Seconds into the cycle → (arrow progress 0…1, pointer opacity, ⌘ shown).
    private static func pose(_ t: Double) -> (move: CGFloat, pointer: Double, held: Bool) {
        func ease(_ x: Double) -> CGFloat { CGFloat(x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2) }
        switch t {
        case ..<0.8: return (0, 0, false)                          // rest
        case ..<1.2: return (0, (t - 0.8) / 0.4, false)            // pointer appears
        case ..<1.6: return (0, 1, true)                           // ⌘ down, grab
        case ..<2.6: return (ease((t - 1.6) / 1.0), 1, true)       // drag
        case ..<3.0: return (1, 1, false)                          // drop
        case ..<3.4: return (1, 1 - (t - 3.0) / 0.4, false)        // pointer leaves
        default:     return (1, 0, false)                          // result stays
        }
    }

    var body: some View {
        Group {
            if let start {
                TimelineView(MotionSchedule(start: start, runs: runs, cycle: Self.cycle, moving: Self.moving)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    // After the last run, rest on the final frame.
                    let t = elapsed >= Double(runs) * Self.cycle ? Self.cycle : elapsed.truncatingRemainder(dividingBy: Self.cycle)
                    let p = Self.pose(t)
                    bar(move: p.move, pointer: p.pointer, held: p.held)
                }
            } else {
                let p = Self.pose(Self.cycle)
                bar(move: p.move, pointer: p.pointer, held: p.held)
            }
        }
        // A TimelineView keeps waking up even after its schedule ends, so
        // swap it out for the static frame when playback is over.
        .task(id: start) {
            guard let start else { return }
            let end = start.addingTimeInterval(Double(runs) * Self.cycle + 0.1)
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if !Task.isCancelled { onFinished(start) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Hold ⌘ and drag the » arrow to the right of the apps you hide."))
    }

    private func bar(move: CGFloat, pointer: Double, held: Bool) -> some View {
        HStack(spacing: 16) {
            ZStack(alignment: .leading) {
                // Each icon steps left as the arrow passes it, like the bar
                // making room during a real drag.
                let arrowSlots = move * CGFloat(Self.glyphs.count)
                ForEach(Array(Self.glyphs.enumerated()), id: \.offset) { i, name in
                    let passed = min(max(arrowSlots - CGFloat(i), 0), 1)
                    Image(systemName: name)
                        .frame(width: Self.slot, height: 22)
                        .offset(x: Self.slot * (CGFloat(i) + 1 - passed))
                }
                // The dragged arrow floats above them.
                Image(systemName: "chevron.forward.2")
                    .fontWeight(.semibold)
                    .frame(width: Self.slot, height: 22)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(held ? 0.9 : 0), in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(held ? 0.25 : 0), radius: 2, y: 1)
                    .offset(x: appsWidth * move)
            }
            .frame(width: appsWidth + Self.slot, height: 22, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // The pointer, with ⌘ held while it drags. An overlay, so it
                // never changes the bar's layout.
                HStack(alignment: .top, spacing: 2) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 15))
                        .shadow(color: .black.opacity(0.3), radius: 1)
                    Text("⌘")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.6), lineWidth: 0.5))
                        .opacity(held ? 1 : 0)
                }
                .offset(x: appsWidth * move + 12, y: 12)
                .opacity(pointer)
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(verbatim: "9:41")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(.bottom, 14)   // room for the pointer below the bar
    }
}

/// 30 fps inside the moving spans of `runs` cycles from `start`, one frame at
/// each still span's start, then a last frame and nothing more. Keeps the
/// animation's CPU near zero while it rests and at zero once it's done.
private struct MotionSchedule: TimelineSchedule {
    let start: Date
    let runs: Int
    let cycle: Double
    let moving: [ClosedRange<Double>]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let fps = mode == .lowFrequency ? 1.0 : 30.0
        var offsets: [Double] = []
        for run in 0..<max(runs, 0) {
            let base = Double(run) * cycle
            offsets.append(base)
            for span in moving {
                var t = span.lowerBound
                while t < span.upperBound { offsets.append(base + t); t += 1 / fps }
                offsets.append(base + span.upperBound)
            }
        }
        offsets.append(Double(max(runs, 0)) * cycle)
        var dates = offsets.map { start.addingTimeInterval($0) }.filter { $0 >= startDate }.makeIterator()
        return AnyIterator { dates.next() }
    }
}
