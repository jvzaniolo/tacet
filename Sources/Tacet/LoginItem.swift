import Observation
import ServiceManagement

/// Open at Login, through SMAppService (the app itself is the login item).
///
/// The state lives in macOS, not in Tacet: the user can turn it off in
/// System Settings › General › Login Items & Extensions, so it is read again
/// whenever Settings opens or comes forward. Off by default.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    /// On also while macOS waits for the user's approval in Login Items.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let status = SMAppService.mainApp.status
        if status != self.status { Log.write("Login item: \(Self.describe(status))") }
        self.status = status
    }

    func set(_ on: Bool) {
        lastError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("Login item: \(on ? "register" : "unregister") failed: \(error)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "status \(status.rawValue)"
        }
    }
}
