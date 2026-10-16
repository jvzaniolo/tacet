import AppKit
import SwiftUI

/// The one Tacet window: the welcome and access step until the user has
/// granted access, then the list of apps (in the style of System Settings ›
/// Menu Bar › Allow in the Menu Bar).
@MainActor
final class SettingsWindowController {
    private let model: ShelfModel
    private let guide: ArrowGuide
    private let ui = SettingsUIState()
    private var window: NSWindow?
    private var timer: Timer?

    init(model: ShelfModel, guide: ArrowGuide) {
        self.model = model
        self.guide = guide
    }

    var needsWelcome: Bool { model.access != .granted || !ui.didOnboard }

    func show() {
        model.refresh()
        if window == nil {
            let view = SettingsRoot(model: model, guide: guide, ui: ui)
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
    var didOnboard = UserDefaults.standard.bool(forKey: key) {
        didSet { UserDefaults.standard.set(didOnboard, forKey: Self.key) }
    }
}

private struct SettingsRoot: View {
    let model: ShelfModel
    let guide: ArrowGuide
    let ui: SettingsUIState

    var body: some View {
        Group {
            if model.access == .granted && ui.didOnboard {
                AppListView(model: model, guide: guide)
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
    let guide: ArrowGuide

    private var managed: [ShelfModel.Row] { model.rows.filter { $0.status != .offInSystemSettings } }
    private var offInSettings: [ShelfModel.Row] { model.rows.filter { $0.status == .offInSystemSettings } }

    var body: some View {
        Form {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if model.hasHiddenApps {
                ArrowPlacementSection(guide: guide, hiddenIcons: managed.filter { $0.status == .hidden }.map(\.icon))
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

/// Shown until the arrow is right of the hidden apps (NOTES §15). On first
/// launch macOS puts a new item at the far left, and only a ⌘-drag moves it.
private struct ArrowPlacementSection: View {
    let guide: ArrowGuide
    let hiddenIcons: [NSImage]

    var body: some View {
        Section {
            if guide.state == .inPlace {
                HStack {
                    Label("The arrow is right of your hidden apps.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Check Again") { guide.check() }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PlacementIllustration(icons: hiddenIcons)
                        .frame(maxWidth: .infinity)
                    if guide.state == .misplaced {
                        Text("Some hidden apps appear to the right of the arrow.")
                            .foregroundStyle(.orange)
                    }
                    Text("1. Click Show Hidden Apps.\n2. Hold ⌘ and drag the » arrow to the right of the apps you hide.\n3. Click Check Position.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if guide.state == .checking {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show Hidden Apps") { guide.showForPlacing() }
                            .disabled(guide.placing || guide.state == .checking)
                        Button("Check Position") { guide.check() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(guide.state == .checking)
                    }
                }
            }
        } header: {
            Text("Arrow Position")
        } footer: {
            if guide.state != .inPlace {
                Text("New menu bar items start at the far left, and only you can move them. Hidden apps then show up to the left of the arrow.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A sketch of the menu bar: the arrow moves from the far left to the right
/// of the hidden apps, as the ⌘-drag should.
private struct PlacementIllustration: View {
    let icons: [NSImage]

    private static let slot: CGFloat = 28
    private var count: Int { max(1, min(icons.count, 4)) }

    var body: some View {
        PhaseAnimator([false, true]) { placed in
            HStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    HStack(spacing: 10) {
                        ForEach(0..<count, id: \.self) { i in
                            icon(i).frame(width: 18, height: 18)
                        }
                    }
                    .offset(x: placed ? 0 : Self.slot)
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.forward.2")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18, height: 18)
                        Text("⌘").font(.caption2.bold()).opacity(placed ? 0 : 1)
                    }
                    .offset(x: placed ? CGFloat(count) * Self.slot : 0, y: 7)
                }
                .frame(width: CGFloat(count + 1) * Self.slot - 10, height: 22, alignment: .leading)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("12:00").font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        } animation: { _ in
            .easeInOut(duration: 0.9).delay(1.2)
        }
    }

    @ViewBuilder private func icon(_ i: Int) -> some View {
        if i < icons.count {
            Image(nsImage: icons[i]).resizable()
        } else {
            Image(systemName: "app.dashed").resizable()
        }
    }
}
