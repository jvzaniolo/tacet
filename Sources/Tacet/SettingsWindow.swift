import AppKit
import SwiftUI

/// The one Tacet window: the welcome and access step until the user has
/// granted access, then the list of apps (in the style of System Settings ›
/// Menu Bar › Allow in the Menu Bar).
@MainActor
final class SettingsWindowController {
    private let model: ShelfModel
    private let hotkey: Hotkey
    private let loginItem: LoginItem
    private let ui = SettingsUIState()
    private var window: NSWindow?
    private var timer: Timer?

    init(model: ShelfModel, hotkey: Hotkey, loginItem: LoginItem) {
        self.model = model
        self.hotkey = hotkey
        self.loginItem = loginItem
    }

    var needsWelcome: Bool { model.access != .granted || !ui.didOnboard }

    func show() {
        model.refresh()
        loginItem.refresh()
        hotkey.retryIfTaken()
        if window == nil {
            let view = SettingsRoot(model: model, hotkey: hotkey, loginItem: loginItem, ui: ui)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Tacet"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRefreshing(false) }
            }
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRefreshing() }
            }
            // Back from System Settings › Login Items & Extensions.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loginItem.refresh() }
            }
            self.window = window
        }
        if let window { AppFocus.show(window) }
        updateRefreshing()
    }

    /// There's no change notification for these switches: while the window
    /// is on screen, re-read them every second so changes made in System
    /// Settings and newly tracked apps show up. Paused while the window is
    /// hidden, covered or minimized (review §2.1).
    private func updateRefreshing() {
        guard let window else { return }
        setRefreshing(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func setRefreshing(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            model.refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

@MainActor
@Observable
final class SettingsUIState {
    private static let key = "didOnboard.v3"
    let recorder = ShortcutRecording()
    /// The app row under the pointer, which shows its ⋯ button.
    var hoveredRow: String?

    var didOnboard = UserDefaults.standard.bool(forKey: key) {
        didSet { UserDefaults.standard.set(didOnboard, forKey: Self.key) }
    }
}

private struct SettingsRoot: View {
    let model: ShelfModel
    let hotkey: Hotkey
    let loginItem: LoginItem
    let ui: SettingsUIState

    var body: some View {
        VStack(spacing: 0) {
            if model.access == .granted && ui.didOnboard {
                AppListView(model: model, hotkey: hotkey, loginItem: loginItem, ui: ui)
            } else {
                WelcomeView(model: model, ui: ui)
            }
            if BuildInfo.isBeta {
                // "Beta 2 (0.1.0) · ends on December 15, 2026"
                Text("Beta \(BuildInfo.betaLabel) · ends on \(BuildInfo.expiryText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
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
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("Welcome to Tacet").font(.title2.bold())
            }
            Point(icon: "switch.2", title: "Tacet uses the macOS switches",
                  text: "It hides apps with the “Allow in the Menu Bar” switches in System Settings › Menu Bar. macOS does the hiding, so Notification Center, Focus and the camera and microphone indicators keep working.")
            Point(icon: "eye.slash", title: "Hidden apps show as off in System Settings",
                  text: "Click « in the menu bar to bring them back. If anything ever goes wrong, turn them back on in System Settings › Menu Bar.")
            Point(icon: "arrow.left.arrow.right", title: "Tacet arranges the icons",
                  text: "Hidden apps sit left of the arrow, always-hidden ones further left. Tacet keeps that order, so there’s nothing to drag.")
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
                    Text("macOS keeps the switches and the order of the menu bar icons in two settings folders. In the next window, hold ⌘ and select “\(ContainerPrefs.controlCenter.appID)” and “\(ContainerPrefs.menuBar.appID)” (the only ones you can click), then click Grant Access. Tacet changes only the “Allow in the Menu Bar” switches and the order of the icons.")
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
    let hotkey: Hotkey
    let loginItem: LoginItem
    let ui: SettingsUIState

    private var managed: [ShelfModel.Row] { model.rows.filter { $0.status == .visible || $0.status == .hidden } }
    private var alwaysHidden: [ShelfModel.Row] { model.rows.filter { $0.status == .alwaysHidden } }
    private var offInSettings: [ShelfModel.Row] { model.rows.filter { $0.status == .offInSystemSettings } }

    var body: some View {
        Form {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            GeneralSection(hotkey: hotkey, loginItem: loginItem, recorder: ui.recorder)

            Section {
                if managed.isEmpty {
                    Text("No apps yet.").foregroundStyle(.secondary)
                }
                ForEach(managed) { row in
                    AppRow(row: row) {
                        // ⋯ on hover; the same menu on right-click.
                        Menu {
                            keepAlwaysHidden(row)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .opacity(ui.hoveredRow == row.id ? 1 : 0)
                        .help(Text("More"))
                        .accessibilityLabel(Text("More"))
                        Toggle("Hide \(row.name) in Tacet", isOn: Binding(
                            get: { row.status == .hidden },
                            set: { model.setHidden(row.bundleID, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .onHover { inside in
                        if inside { ui.hoveredRow = row.id } else if ui.hoveredRow == row.id { ui.hoveredRow = nil }
                    }
                    .contextMenu { keepAlwaysHidden(row) }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide in Tacet")
                    Text("Apps turned on here hide behind Tacet’s arrow.")
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }

            // Shown even when empty (header only), so the place is known.
            Section {
                ForEach(alwaysHidden) { row in
                    AppRow(row: row) {
                        Button("Move Back") { model.setAlwaysHidden(row.bundleID, false) }
                            .controlSize(.small)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always Hidden")
                    // The arrow as the bar draws it while closed (ShelfController).
                    let arrow = Image(systemName: "chevron.backward.2")
                    Text("Hold ⌥ and click \(arrow) to see these items.")
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    private func keepAlwaysHidden(_ row: ShelfModel.Row) -> some View {
        Button("Keep Always Hidden") { model.setAlwaysHidden(row.bundleID, true) }
    }
}

// MARK: Open at Login and the shortcut

private struct GeneralSection: View {
    let hotkey: Hotkey
    let loginItem: LoginItem
    let recorder: ShortcutRecording

    var body: some View {
        Section {
            Toggle("Open at Login", isOn: Binding(
                get: { loginItem.isOn },
                set: { loginItem.set($0) }
            ))
            .toggleStyle(.switch)
            if loginItem.needsApproval {
                // Turned off in System Settings, or waiting for the user's OK.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tacet is turned off in System Settings › General › Login Items & Extensions. Turn it on there to open Tacet at login.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items & Extensions…") { loginItem.openLoginItems() }
                }
            }
            if let error = loginItem.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("General")
        }

        Section {
            LabeledContent("Toggle Tacet") {
                ShortcutRecorder(hotkey: hotkey, recorder: recorder)
            }
            // The ⌥ variant: read-only, it follows the shortcut.
            if let variant = hotkey.variant {
                LabeledContent("Toggle Always Hidden") {
                    Text(verbatim: variant.display)
                        .foregroundStyle(.secondary)
                        .frame(width: 130)
                }
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Keyboard Shortcuts")
        }
    }

    private var message: LocalizedStringKey? {
        switch recorder.problem {
        case .needsModifier: return "Use ⌘, ⌥ or ⌃ in the shortcut."
        case .system(let keys): return "\(keys) is used by macOS. Choose a different shortcut."
        case .taken(let keys): return "\(keys) is already used by another app. Choose a different shortcut."
        case nil:
            if let shortcut = hotkey.shortcut, hotkey.isTaken {
                return "\(shortcut.display) is already used by another app. Choose a different shortcut."
            }
            // The ⌥ variant (shown in the arrow's menu) is taken.
            if let variant = hotkey.variant, hotkey.isVariantTaken {
                return "\(variant.display) is already used by another app."
            }
            return nil
        }
    }
}

/// Recording a new shortcut, as in System Settings › Keyboard Shortcuts:
/// click the field, then type it; Esc or a click elsewhere keeps the current
/// one, ⌫ clears it (as does the ✕ in the field). A local
/// monitor on Tacet's own window, so no permission is involved. The current
/// shortcut is paused meanwhile, so typing it again reaches the recorder.
/// (A class, not @State: SwiftUI's @State is a macro the Command Line
/// Tools can't expand.)
@MainActor
@Observable
final class ShortcutRecording {
    private(set) var isRecording = false
    private(set) var held: NSEvent.ModifierFlags = []
    var problem: Hotkey.Problem?
    @ObservationIgnored private var monitor: Any?

    func start(_ hotkey: Hotkey) {
        problem = nil
        hotkey.pause()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event, hotkey) ?? false }
            return consumed ? nil : event
        }
    }

    /// True when the event is the recorder's (not passed on).
    private func handle(_ event: NSEvent, _ hotkey: Hotkey) -> Bool {
        let shortcut = Shortcut(event: event)
        if event.type == .flagsChanged {
            held = shortcut.modifiers
            return false
        }
        if event.keyCode == 53 && shortcut.modifiers.isEmpty {   // Esc: cancel
            problem = nil
            stop(hotkey)
            return true
        }
        if (event.keyCode == 51 || event.keyCode == 117) && shortcut.modifiers.isEmpty {   // ⌫ ⌦: clear
            problem = nil
            hotkey.remove()
            stop(hotkey)
            return true
        }
        problem = hotkey.change(to: shortcut)
        // Without ⌘, ⌥ or ⌃, keep listening for a better one.
        if problem != .needsModifier { stop(hotkey) }
        return true
    }

    func stop(_ hotkey: Hotkey) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        held = []
        hotkey.resume()
    }
}

/// The shortcut field: the keys, and a ✕ to clear them; while recording,
/// a prompt and the modifiers held so far, with the accent outline.
private struct ShortcutRecorder: View {
    let hotkey: Hotkey
    let recorder: ShortcutRecording

    var body: some View {
        Button {
            if recorder.isRecording { recorder.stop(hotkey) } else { recorder.start(hotkey) }
        } label: {
            HStack(spacing: 4) {
                Group {
                    if recorder.isRecording {
                        if recorder.held.isEmpty {
                            Text("Type Shortcut").foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: Shortcut.symbols(recorder.held))
                        }
                    } else if let shortcut = hotkey.shortcut {
                        Text(verbatim: shortcut.display)
                    } else {
                        Text("Record Shortcut").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                if hotkey.shortcut != nil && !recorder.isRecording {
                    Button {
                        recorder.problem = nil
                        hotkey.remove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear Shortcut"))
                    .accessibilityLabel(Text("Clear Shortcut"))
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 130, height: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(recorder.isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: recorder.isRecording ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Click to record a new shortcut."))
        .onDisappear { recorder.stop(hotkey) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop(hotkey) }
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
        .contentShape(Rectangle())   // hover and right-click across the row
    }
}
