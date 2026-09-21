import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ValidationFailure.assertion(message)
    }
}

private func matches(_ source: String, _ pattern: String) throws -> Bool {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)
    return regex.firstMatch(in: source, range: range) != nil
}

@main
private enum OverlayRestingStateValidator {
    static func main() throws {
        let activeStates: [OverlayState] = [
            .recording(isCommandMode: false),
            .recording(isCommandMode: true),
            .processing(isCommandMode: false),
            .processing(isCommandMode: true),
        ]

        // The app activation and Space change observers bring any overlay that
        // is not `.hidden` back on screen. With "Show When Idle" off, launch
        // has to rest in `.hidden` or the first app switch shows the pill.
        try require(
            OverlayState.resting(hideIdleState: true) == .hidden,
            "with Show When Idle off the overlay does not rest hidden, so an app switch shows it"
        )
        try require(
            OverlayState.resting(hideIdleState: false) == .idle,
            "with Show When Idle on the overlay does not rest idle"
        )

        // A resting overlay settles into the state for the current choice,
        // whichever resting state it was in before.
        for start in [OverlayState.hidden, .idle] {
            try require(
                start.settled(hideIdleState: true) == .hidden,
                "a resting overlay in \(start) does not settle hidden with Show When Idle off"
            )
            try require(
                start.settled(hideIdleState: false) == .idle,
                "a resting overlay in \(start) does not settle idle with Show When Idle on"
            )
        }

        // Settling never interrupts a recording or its processing.
        for active in activeStates {
            for hideIdleState in [true, false] {
                try require(
                    active.settled(hideIdleState: hideIdleState) == active,
                    "settling moved an active overlay out of \(active)"
                )
            }
        }

        // A missing-permission callout brings the window forward without
        // changing the state. When it clears before any recording, the overlay
        // must still be hidden rather than left on screen.
        let launched = OverlayState.resting(hideIdleState: true)
        try require(
            launched.settled(hideIdleState: true) == .hidden,
            "clearing a permission callout shown at launch does not return the overlay to hidden"
        )

        // Turning Show When Idle on right after launch has to bring the idle
        // overlay back, not leave it stuck hidden until the next recording.
        try require(
            launched.settled(hideIdleState: false) == .idle,
            "turning Show When Idle on after launch leaves the overlay hidden"
        )

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let managerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Whishpermate/Whispermate/Services/OverlayWindowManager.swift"
            ),
            encoding: .utf8
        )
        // OverlayWindowManager cannot be built outside the app, so these two
        // checks cover the wiring the compiled type cannot. A nested
        // OverlayState in the manager would shadow the one validated above.
        let declaresOwnState = try matches(managerSource, #"\benum\s+OverlayState\b"#)
        let startsAtRest = try matches(
            managerSource,
            #"var\s+overlayState\s*:\s*OverlayState\s*=\s*(OverlayState)?\.resting\("#
        )
        try require(
            !declaresOwnState,
            "OverlayWindowManager declares its own OverlayState, so this validator no longer covers it"
        )
        try require(
            startsAtRest,
            "the overlay does not start in its resting state, so launch with Show When Idle off leaves it idle"
        )

        print("macOS overlay resting state contracts passed")
    }
}
