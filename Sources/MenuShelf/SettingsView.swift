import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "MenuShelf Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        model.rescan(log: true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    // Note: the macOS 27 SDK implements @State as a macro whose plugin ships
    // only with Xcode, so view state lives on the model instead.
    private var showSystem: Bool { model.showSystemItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.hasAccessibility {
                permissionBanner
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Menu bar items").font(.title2.bold())
            Text("Mark an app Hidden to tuck all of its menu bar items away. macOS 27 hides per app, so an app's items always share one setting.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HidingBackendStatus(hider: model.hider)
        }
        .padding(16)
    }

    private var permissionBanner: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Accessibility access is off").font(.headline)
            Text("MenuShelf needs it to see other apps' menu bar items.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Accessibility Settings…") { OnboardingController.openAccessibilitySettings() }
                Button("Check Again") { model.rescan(log: true) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var visibleApps: [MenuBarApp] {
        showSystem ? model.apps : model.apps.filter { !$0.isSystem }
    }

    private var list: some View {
        List {
            ForEach(visibleApps) { app in
                Section {
                    ForEach(app.items) { item in
                        ItemRow(item: item)
                    }
                } header: {
                    AppHeader(app: app, isHidden: Binding(
                        get: { model.isHidden(app) },
                        set: { model.setHidden($0, for: app) }
                    ))
                }
            }
        }
        .overlay {
            if model.apps.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No menu bar items found.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Show Apple items", isOn: $model.showSystemItems).toggleStyle(.checkbox)
            Spacer()
            if let date = model.lastScan {
                Text("Scanned \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Dump to Console") { model.dumpToConsole() }
            Button("Refresh") { model.rescan(log: true) }
                .disabled(model.isScanning)
        }
        .padding(12)
    }
}

private struct AppHeader: View {
    let app: MenuBarApp
    @Binding var isHidden: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.headline).foregroundStyle(.primary)
                Text(app.bundleID ?? "no bundle ID").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(app.items.count) item\(app.items.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hidden", isOn: $isHidden)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct ItemRow: View {
    let item: MenuBarItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                if let id = item.identifier {
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let frame = item.frame {
                Text("x \(Int(frame.minX))  w \(Int(frame.width))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Open") { AX.press(item.element) }
                .controlSize(.small)
        }
    }
}

private struct HidingBackendStatus: View {
    let hider: AppHiding

    var body: some View {
        Label(hider.statusText, systemImage: hider.isOperational ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(hider.isOperational ? Color.secondary : Color.orange)
    }
}
