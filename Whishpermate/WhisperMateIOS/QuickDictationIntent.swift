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

@MainActor
final class QuickDictationIntentBridge {
    static let shared = QuickDictationIntentBridge()
    static let startNotification = Notification.Name("AIDictation.quickDictationIntent.start")

    private var continuation: CheckedContinuation<String, Error>?

    var isPending: Bool { continuation != nil }

    private init() {}

    func begin() async throws -> String {
        guard continuation == nil else {
            throw QuickDictationIntentError.alreadyRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            NotificationCenter.default.post(name: Self.startNotification, object: nil)
        }
    }

    func complete(with transcript: String) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: transcript)
    }

    func fail(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

enum QuickDictationIntentError: LocalizedError {
    case alreadyRunning
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A Quick Dictation is already running."
        case .couldNotStart:
            return "AI Dictation could not start recording. Open the app and try again."
        }
    }
}
