import Foundation

enum LiveLaunchRoute: Equatable {
    case voice

    static let scheme = "phoneclaw"

    static var voiceURL: URL {
        URL(string: "\(scheme)://live?mode=voice")!
    }

    static func parse(_ url: URL) -> LiveLaunchRoute? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let host = url.host?.lowercased()
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        guard host == "live" || path == "live" else { return nil }
        return .voice
    }
}

enum LiveLaunchRequestStore {
    private static let pendingVoiceLaunchKey = "phoneclaw.pendingLiveVoiceLaunch"

    static func requestVoiceLaunch() {
        UserDefaults.standard.set(true, forKey: pendingVoiceLaunchKey)
    }

    static func consumeVoiceLaunchRequest() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingVoiceLaunchKey) else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: pendingVoiceLaunchKey)
        return true
    }
}
