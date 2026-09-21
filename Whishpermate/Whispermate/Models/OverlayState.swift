import Foundation

/// What the recording overlay is doing. `OverlayWindowManager` owns the current
/// value and moves between states through `transition(to:)`.
enum OverlayState: Equatable {
    case hidden
    case idle
    case recording(isCommandMode: Bool)
    case processing(isCommandMode: Bool)
}

extension OverlayState {
    /// Where the overlay rests when nothing is being recorded or processed.
    ///
    /// With "Show When Idle" off the overlay rests `.hidden`, not `.idle` with
    /// its window ordered out. The observers that follow the frontmost app and
    /// the active Space bring any overlay that is not `.hidden` back on screen,
    /// so an overlay left `.idle` reappears on the next app switch.
    static func resting(hideIdleState: Bool) -> OverlayState {
        hideIdleState ? .hidden : .idle
    }

    /// The state a resting overlay settles into for the current "Show When
    /// Idle" choice. Recording and processing are left alone.
    func settled(hideIdleState: Bool) -> OverlayState {
        switch self {
        case .hidden, .idle:
            return .resting(hideIdleState: hideIdleState)
        case .recording, .processing:
            return self
        }
    }
}
