import AppKit
import SwiftUI

/// Permissions window. MenuShelf never changes System Settings itself: it
/// explains each permission and opens the right pane for the user.
/// - Accessibility: read item positions when the user finishes editing.
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    private var timer: Timer?
    private let state = PermissionState()
    private let onAccessibilityGranted: () -> Void
    private var reportedGrant = false

    init(onGranted: @escaping () -> Void) {
        self.onAccessibilityGranted = onGranted
    }

    func showIfNeeded() {
        state.refresh()
        if !state.accessibility { show() }
    }

    func show() {
        state.refresh()
        if window == nil {
            let view = PermissionsView(state: state, close: { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "MenuShelf Permissions"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)

        // Grants have no callback; poll while the window is up.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        state.refresh()
        if state.accessibility, !reportedGrant {
            reportedGrant = true
            onAccessibilityGranted()
        }
        if window?.isVisible != true {
            timer?.invalidate()
            timer = nil
        }
    }

    static func openAccessibilitySettings() {
        // Registers MenuShelf in the list (switched off) so the user only has
        // to flip the switch. This does not grant anything.
        _ = AX.isTrusted(prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
@Observable
final class PermissionState {
    var accessibility = false

    func refresh() {
        accessibility = AX.isTrusted(prompt: false)
    }
}

private struct PermissionsView: View {
    let state: PermissionState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MenuShelf needs one permission").font(.title2.bold())
            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                badge: "Required",
                text: "Lets MenuShelf read where your menu bar icons are when you finish editing the layout, to know which apps you put left of the divider. Hiding itself needs no permission.",
                granted: state.accessibility,
                action: OnboardingController.openAccessibilitySettings
            )
            Text("You turn this on yourself in System Settings → Privacy & Security. MenuShelf never changes your settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.accessibility)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let badge: String
    let text: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Text(badge).font(.caption).foregroundStyle(.secondary)
                }
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if granted {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open System Settings…", action: action)
                }
            }
        }
    }
}
