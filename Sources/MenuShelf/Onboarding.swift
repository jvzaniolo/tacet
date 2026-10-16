import AppKit
import SwiftUI

/// Shown while Accessibility is not granted. MenuShelf never changes System
/// Settings itself: it explains why and opens the right pane for the user.
@MainActor
final class OnboardingController {
    private var window: NSWindow?
    private var timer: Timer?
    private let onGranted: () -> Void

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    func showIfNeeded() {
        guard !AX.isTrusted(prompt: false) else { return }
        if window == nil {
            let view = OnboardingView(
                openSettings: { Self.openAccessibilitySettings() },
                checkAgain: { [weak self] in self?.check() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "MenuShelf needs Accessibility"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)

        // The grant has no callback; poll while the window is up.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard AX.isTrusted(prompt: false) else { return }
        timer?.invalidate()
        timer = nil
        window?.close()
        onGranted()
    }

    static func openAccessibilitySettings() {
        // Registers MenuShelf in the Accessibility list (switched off) so the
        // user only has to flip the switch. This does not grant anything.
        _ = AX.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct OnboardingView: View {
    let openSettings: () -> Void
    let checkAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "accessibility")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Allow MenuShelf to use Accessibility")
                    .font(.title2.bold())
            }
            Text("""
            On macOS 27 the menu bar is drawn as a single window, so MenuShelf \
            can only see other apps' menu bar items through Accessibility. It \
            uses it to list items, read their position and name, and open an \
            item when you pick it from MenuShelf's menu.
            """)
            Text("""
            Click the button below, then turn on MenuShelf under \
            Privacy & Security → Accessibility. This window closes by itself \
            once access is on.
            """)
            .foregroundStyle(.secondary)
            HStack {
                Button("Check Again", action: checkAgain)
                Spacer()
                Button("Open Accessibility Settings…", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
