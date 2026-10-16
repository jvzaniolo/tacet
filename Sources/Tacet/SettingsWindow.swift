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
                AppListView(model: model)
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
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: The list

private struct AppListView: View {
    let model: ShelfModel

    private var managed: [ShelfModel.Row] { model.rows.filter { $0.status != .offInSystemSettings } }
    private var offInSettings: [ShelfModel.Row] { model.rows.filter { $0.status == .offInSystemSettings } }

    var body: some View {
        Form {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Section {
                if managed.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach(managed) { row in
                    AppRow(row: row) {
                        Toggle("Show \(row.name)", isOn: Binding(
                            get: { row.status == .visible },
                            set: { model.setHidden(row.bundleID, !$0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            } header: {
                Text("Show in the Menu Bar")
            } footer: {
                Text("Apps you switch off are hidden. Click « in the menu bar to show them. Apps appear here after their first time in the menu bar.")
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
                    HStack(alignment: .firstTextBaseline) {
                        Text("Tacet doesn’t show these. Turn them on in System Settings to use them.")
                            .foregroundStyle(.secondary)
                        Spacer()
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
        .frame(minHeight: 420)
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
