import AppIntents
import Foundation

struct StartPhoneClawLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Start PhoneClaw LIVE"
    static var description = IntentDescription("Open PhoneClaw directly in LIVE voice mode.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveLaunchRequestStore.requestVoiceLaunch()
        return .result()
    }
}

struct PhoneClawAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPhoneClawLiveIntent(),
            phrases: [
                "Start \(.applicationName) LIVE",
                "Open \(.applicationName) LIVE",
                "开始 \(.applicationName) 语音",
                "打开 \(.applicationName) LIVE",
                "和 \(.applicationName) 对话",
                "用 \(.applicationName) 开始语音"
            ],
            shortTitle: "LIVE",
            systemImageName: "waveform"
        )
    }
}
