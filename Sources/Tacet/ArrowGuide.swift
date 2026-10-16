import AppKit
import Observation

/// Where Tacet's arrow sits relative to the hidden apps (NOTES §15).
///
/// A status item with a never-seen autosave name lands at the far left of the
/// bar, so on first launch the arrow is left of everything and revealed apps
/// show up to its right. macOS offers no permission-free way to place it, so
/// the user ⌘-drags it once. Tacet checks the result from its own item's
/// frame: the bar is right-anchored, so revealing apps to the arrow's right
/// pushes the arrow left by their width, while apps to its left don't move it.
@MainActor
@Observable
final class ArrowGuide {
    enum State: Equatable {
        case unknown      // not checked yet
        case checking
        case inPlace      // revealing doesn't move the arrow
        case misplaced    // revealed apps appear right of the arrow
    }

    private static let key = "arrowPlaced.v1"

    private(set) var state: State
    /// Hidden apps are shown (pinned) so the user can ⌘-drag the arrow.
    var placing = false

    /// Set by `ShelfController`.
    @ObservationIgnored var showForPlacing: () -> Void = {}
    @ObservationIgnored var check: () -> Void = {}

    init() {
        state = UserDefaults.standard.bool(forKey: Self.key) ? .inPlace : .unknown
    }

    func set(_ state: State) {
        self.state = state
        switch state {
        case .inPlace: UserDefaults.standard.set(true, forKey: Self.key)
        case .misplaced: UserDefaults.standard.set(false, forKey: Self.key)
        case .unknown, .checking: break
        }
    }

    /// A shift of the arrow's x between concealed and revealed. Revealed apps
    /// are at least ~16 pt wide each; text items next to the arrow (a timer)
    /// can change by a few points meanwhile.
    static func judge(shift: CGFloat) -> State? {
        if shift > 12 { return .misplaced }
        if abs(shift) < 4 { return .inPlace }
        return nil
    }
}
