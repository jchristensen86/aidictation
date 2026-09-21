import AppIntents
import Foundation

@available(iOS 16.0, *)
struct QuickDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Dictation"
    static var description = IntentDescription(
        "Record a dictation in AI Dictation, copy the finished transcript, and return it to Shortcuts."
    )
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let transcript = try await QuickDictationIntentBridge.shared.begin()
        return .result(value: transcript, dialog: "Dictation copied to the clipboard")
    }
}

@available(iOS 16.0, *)
struct AIDictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickDictationIntent(),
            phrases: [
                "Quick dictation with \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Quick Dictation",
            systemImageName: "mic.fill"
        )
    }
}

/// Carries one Quick Dictation request from the Shortcuts intent to the
/// recording screen and back.
///
/// A request waits for the screen to pick it up (the app may still be
/// launching), then for recording to start (prompts such as microphone access
/// or cloud consent can delay it), then for the recording to finish. Every
/// request ends exactly once: with the transcript, or with an error when it is
/// declined, fails, times out, or the Shortcut is cancelled. Recordings that
/// were not started for a request are never touched.
@MainActor
final class QuickDictationIntentBridge {
    static let shared = QuickDictationIntentBridge()
    static let startNotification = Notification.Name("AIDictation.quickDictationIntent.start")

    enum Phase: Equatable {
        case idle
        case waitingForApp
        case starting
        case recording
    }

    private(set) var phase: Phase = .idle
    private var continuation: CheckedContinuation<String, Error>?
    private var requestID = 0
    private let appReadyTimeout: TimeInterval
    private let startTimeout: TimeInterval

    /// True while a request is waiting for its recording to start.
    var isStartPending: Bool { phase == .starting }

    init(appReadyTimeout: TimeInterval = 15, startTimeout: TimeInterval = 120) {
        self.appReadyTimeout = appReadyTimeout
        self.startTimeout = startTimeout
    }

    /// Called by the intent. Suspends until the request ends.
    func begin() async throws -> String {
        guard phase == .idle else {
            throw QuickDictationIntentError.alreadyRunning
        }
        requestID &+= 1
        let request = requestID

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.phase = .waitingForApp
                self.scheduleTimeout(
                    after: self.appReadyTimeout,
                    request: request,
                    while: .waitingForApp,
                    error: .appNotReady
                )
                NotificationCenter.default.post(name: Self.startNotification, object: nil)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(request: request)
            }
        }
    }

    /// Called by the recording screen when it is on screen and listening.
    /// Returns true when there is a request it should start recording for.
    func takeStartRequest() -> Bool {
        guard phase == .waitingForApp else { return false }
        phase = .starting
        scheduleTimeout(after: startTimeout, request: requestID, while: .starting, error: .couldNotStart)
        return true
    }

    /// Called whenever the recorder changes state. The first non-idle state
    /// after the start request binds that recording to the request; returning
    /// to idle without a transcript ends the request.
    func recorderStateChanged(isIdle: Bool) {
        switch phase {
        case .starting where !isIdle:
            phase = .recording
        case .recording where isIdle:
            // A successful recording delivers its transcript right after the
            // recorder resets, so give it a turn before treating idle as an end.
            let request = requestID
            Task { @MainActor in
                await Task.yield()
                guard self.requestID == request, self.phase == .recording else { return }
                self.resolve(.failure(QuickDictationIntentError.noTranscript))
            }
        default:
            break
        }
    }

    /// Called when the recorder shows an error, such as microphone access being
    /// denied, a subscription limit, or a transcription failure.
    func recorderReportedError(_ message: String) {
        guard phase == .starting || phase == .recording else { return }
        resolve(.failure(QuickDictationIntentError.recordingFailed(message)))
    }

    /// Called when the user dismisses a prompt without allowing recording.
    func startDeclined() {
        guard phase == .starting else { return }
        resolve(.failure(QuickDictationIntentError.notStarted))
    }

    /// Called with every finished recording. Returns true when the recording
    /// belonged to the request and its transcript was returned to Shortcuts,
    /// so the caller should copy it and play the completion haptic.
    func finish(with transcript: String) -> Bool {
        guard phase == .recording || phase == .starting else { return false }
        guard !transcript.isEmpty else {
            resolve(.failure(QuickDictationIntentError.noTranscript))
            return false
        }
        resolve(.success(transcript))
        return true
    }

    /// Ends the current request with an error. Does nothing when idle.
    func fail(_ error: QuickDictationIntentError) {
        guard phase != .idle else { return }
        resolve(.failure(error))
    }

    private func cancel(request: Int) {
        guard request == requestID, phase != .idle else { return }
        resolve(.failure(CancellationError()))
    }

    private func scheduleTimeout(
        after seconds: TimeInterval,
        request: Int,
        while expected: Phase,
        error: QuickDictationIntentError
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.requestID == request, self.phase == expected else { return }
            self.resolve(.failure(error))
        }
    }

    private func resolve(_ result: Result<String, Error>) {
        phase = .idle
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

enum QuickDictationIntentError: LocalizedError, Equatable {
    case alreadyRunning
    case appNotReady
    case busy
    case couldNotStart
    case notStarted
    case noTranscript
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A Quick Dictation is already running."
        case .appNotReady:
            return "AI Dictation isn't ready yet. Open the app, finish setting it up, and run the shortcut again."
        case .busy:
            return "Finish the dictation in progress, then run the shortcut again."
        case .couldNotStart:
            return "AI Dictation could not start recording. Open the app and try again."
        case .notStarted:
            return "Recording was not started."
        case .noTranscript:
            return "The dictation ended without a transcript."
        case let .recordingFailed(message):
            return message
        }
    }
}
