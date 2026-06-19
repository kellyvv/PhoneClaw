import Foundation

enum LiveLaunchRoute: Equatable {
    case liveLand
    case voice

    static let scheme = "phoneclaw"

    static var liveLandURL: URL {
        URL(string: "\(scheme)://liveland")!
    }

    static var voiceURL: URL {
        URL(string: "\(scheme)://live?mode=voice")!
    }

    static func parse(_ url: URL) -> LiveLaunchRoute? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        let host = url.host?.lowercased()
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if host == "liveland" || path == "liveland" {
            return .liveLand
        }
        if host == "live" || path == "live" {
            return .voice
        }
        return nil
    }
}

enum LiveLaunchRequestStore {
    private static let pendingLiveLandLaunchKey = "phoneclaw.pendingLiveLandLaunch"
    private static let pendingVoiceLaunchKey = "phoneclaw.pendingLiveVoiceLaunch"

    static func requestLiveLandLaunch() {
        UserDefaults.standard.set(true, forKey: pendingLiveLandLaunchKey)
    }

    static func consumeLiveLandLaunchRequest() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingLiveLandLaunchKey) else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: pendingLiveLandLaunchKey)
        return true
    }

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
