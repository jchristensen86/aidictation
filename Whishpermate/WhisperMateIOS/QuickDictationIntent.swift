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
