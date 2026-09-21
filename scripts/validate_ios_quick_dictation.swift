import Foundation

private enum ValidationFailure: Error {
    case assertion(String)
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

@MainActor
private func waitForRequest(_ bridge: QuickDictationIntentBridge) async throws {
    for _ in 0..<1_000 {
        if bridge.phase == .waitingForApp { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ValidationFailure.assertion("request did not reach the app")
}

@MainActor
private func requireCancellation(_ task: Task<String, Error>) async throws {
    do {
        _ = try await task.value
        throw ValidationFailure.assertion("cancelled request returned a transcript")
    } catch is CancellationError {}
}

@main
struct QuickDictationValidation {
    @MainActor
    static func main() async throws {
        for isRecording in [false, true] {
            let bridge = QuickDictationIntentBridge()
            var cancellations = 0
            let task = Task { try await bridge.begin() }
            try await waitForRequest(bridge)
            try require(bridge.takeStartRequest(), "app must accept its request")
            bridge.setCancellationHandler { cancellations += 1 }
            if isRecording { bridge.recorderStateChanged(isIdle: false) }
            task.cancel()
            try await requireCancellation(task)
            try require(cancellations == 1, "cancellation must stop owned work exactly once")
            try require(bridge.phase == .idle, "cancelled request must become idle")
            try require(!bridge.finish(with: "Late result"), "cancelled request must reject late text")
        }

        let earlyBridge = QuickDictationIntentBridge()
        let earlyTask = Task { try await earlyBridge.begin() }
        earlyTask.cancel()
        try await requireCancellation(earlyTask)
        try require(earlyBridge.phase == .idle, "pre-cancelled task must not start a request")

        let waitingBridge = QuickDictationIntentBridge()
        let waitingTask = Task { try await waitingBridge.begin() }
        try await waitForRequest(waitingBridge)
        waitingTask.cancel()
        try await requireCancellation(waitingTask)
        try require(!waitingBridge.takeStartRequest(), "cancelled cold launch must not start recording")

        let timeoutBridge = QuickDictationIntentBridge(startTimeout: 0.02)
        var timedOutCancellations = 0
        let timeoutTask = Task { try await timeoutBridge.begin() }
        try await waitForRequest(timeoutBridge)
        try require(timeoutBridge.takeStartRequest(), "timeout request must start")
        timeoutBridge.setCancellationHandler { timedOutCancellations += 1 }
        do {
            _ = try await timeoutTask.value
            throw ValidationFailure.assertion("stalled startup unexpectedly succeeded")
        } catch QuickDictationIntentError.couldNotStart {}
        try require(timedOutCancellations == 1, "startup timeout must cancel pending work")
        try require(timeoutBridge.phase == .idle, "timed-out request must become idle")

        let bridge = QuickDictationIntentBridge()
        var firstCancellations = 0
        var nextCancellations = 0
        let first = Task { try await bridge.begin() }
        try await waitForRequest(bridge)
        try require(bridge.takeStartRequest(), "first request must start")
        bridge.setCancellationHandler { firstCancellations += 1 }
        bridge.recorderStateChanged(isIdle: false)
        try require(bridge.finish(with: "Finished text"), "finished request must deliver its text")
        let text = try await first.value
        try require(text == "Finished text", "completed transcript must be preserved")
        try require(firstCancellations == 0, "success must not cancel recording")

        let next = Task { try await bridge.begin() }
        try await waitForRequest(bridge)
        try require(bridge.takeStartRequest(), "next request must start")
        bridge.setCancellationHandler { nextCancellations += 1 }
        first.cancel()
        await Task.yield()
        try require(bridge.phase == .starting, "old cancellation must not affect a new request")
        next.cancel()
        try await requireCancellation(next)
        try require(firstCancellations == 0 && nextCancellations == 1, "only the current owner may be cancelled")

        print("Quick Dictation cancellation, startup timeout, late result, and request ownership: PASS")
    }
}
