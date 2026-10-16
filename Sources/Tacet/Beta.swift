import AppKit
import SwiftUI

/// Build information written into Info.plist by `scripts/build-app.sh`.
///
/// - `TacetBetaExpiry` (ISO 8601): only in beta builds (`BETA=1`). From that
///   moment Tacet stops hiding, turns every switch it changed back on and
///   shows the "beta has ended" window.
/// - `TacetSiteURL`, `TacetFeedbackURL`: links for that window and for
///   "Send Feedback…" (the menu item only exists when a feedback URL is set).
enum BuildInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var shortVersion: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { info["CFBundleVersion"] as? String ?? "?" }
    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var betaExpiry: Date? {
        (info["TacetBetaExpiry"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    static var isBeta: Bool { betaExpiry != nil }
    static var isExpired: Bool { betaExpiry.map { Date() >= $0 } ?? false }

    static var siteURL: URL? { (info["TacetSiteURL"] as? String).flatMap(URL.init(string:)) }

    /// The feedback link with the Tacet and macOS versions added, nothing
    /// else: as subject/body for a mailto:, as query items for a web page.
    static var feedbackURL: URL? {
        guard let raw = info["TacetFeedbackURL"] as? String, !raw.isEmpty,
              var parts = URLComponents(string: raw) else { return nil }
        let versions = "Tacet \(shortVersion) (\(build))\(isBeta ? " beta" : ""), macOS \(macOSVersion)"
        var items = parts.queryItems ?? []
        if parts.scheme == "mailto" {
            items.append(URLQueryItem(name: "subject", value: "Tacet feedback"))
            items.append(URLQueryItem(name: "body", value: "\n\n—\n\(versions)"))
        } else {
            items.append(URLQueryItem(name: "version", value: "\(shortVersion) (\(build))\(isBeta ? " beta" : "")"))
            items.append(URLQueryItem(name: "macos", value: macOSVersion))
        }
        parts.queryItems = items
        return parts.url
    }

    static var expiryText: String {
        betaExpiry.map { $0.formatted(date: .long, time: .omitted) } ?? ""
    }
}

/// "This beta has ended": shown once the beta build expires, and whenever the
/// arrow is clicked after that.
@MainActor
final class BetaExpiredWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: BetaExpiredView()))
            window.title = "Tacet"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppFocus.windowClosing(window) }
            }
            self.window = window
        }
        if let window { AppFocus.show(window) }
    }
}

private struct BetaExpiredView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("This Tacet beta has ended").font(.title2.bold())
            }
            Text("Thank you for testing Tacet! This beta ended on \(BuildInfo.expiryText). Tacet no longer hides anything, and your menu bar apps are all shown again.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Get the latest version on the Tacet website.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit Tacet") { NSApp.terminate(nil) }
                if let site = BuildInfo.siteURL {
                    Button("Visit Website") { NSWorkspace.shared.open(site) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
