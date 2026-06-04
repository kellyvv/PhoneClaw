import Foundation
import AVFoundation

enum TelemetryInstallOutcome: String, Sendable {
    case started
    case completed
    case failed
    case cancelled
}

enum TelemetryModality: String, Sendable {
    case text
    case image
    case audio
    case multimodal

    static func from(hasImages: Bool, hasAudio: Bool) -> TelemetryModality {
        switch (hasImages, hasAudio) {
        case (true, true):
            return .multimodal
        case (true, false):
            return .image
        case (false, true):
            return .audio
        case (false, false):
            return .text
        }
    }
}

enum TelemetryInputLanguage: String, Sendable {
    case zh
    case en
    case ja
    case other

    static func detect(from text: String) -> TelemetryInputLanguage {
        var hanCount = 0
        var kanaCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                kanaCount += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                hanCount += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            default:
                continue
            }
        }

        if kanaCount > 0 {
            return .ja
        }
        if hanCount > 0 {
            return .zh
        }
        if latinCount >= 3 {
            return .en
        }
        return .other
    }
}

enum Telemetry {
    static func recordAppOpen() {
        Task { await TelemetryClient.shared.recordAppOpen() }
    }

    static func endSession() {
        Task { await TelemetryClient.shared.endSession() }
    }

    static func flush() {
        Task { await TelemetryClient.shared.flush() }
    }

    static func recordMessageSent(
        modelID: String,
        modality: TelemetryModality,
        inputLanguage: TelemetryInputLanguage
    ) {
        Task {
            await TelemetryClient.shared.recordMessageSent(
                modelID: modelID,
                modality: modality,
                inputLanguage: inputLanguage
            )
        }
    }

    static func recordFirstResponseReceived(
        modelID: String,
        ttftMs: Double,
        success: Bool,
        failureReason: String? = nil
    ) {
        Task {
            await TelemetryClient.shared.recordFirstResponseReceived(
                modelID: modelID,
                ttftMs: ttftMs,
                success: success,
                failureReason: failureReason
            )
        }
    }

    static func recordModelInstall(
        modelID: String,
        outcome: TelemetryInstallOutcome,
        failureReason: String? = nil
    ) {
        Task {
            await TelemetryClient.shared.recordModelInstall(
                modelID: modelID,
                outcome: outcome,
                failureReason: failureReason
            )
        }
    }

    static func recordTTSStarted(
        backend: String,
        textLength: Int
    ) {
        Task {
            await TelemetryClient.shared.recordTTSStarted(
                backend: backend,
                textLength: textLength
            )
        }
    }

    static func recordTTSGenerated(
        backend: String,
        synthMs: Double,
        audioDuration: TimeInterval,
        sampleRate: Int,
        byteCount: Int,
        textLength: Int
    ) {
        Task {
            await TelemetryClient.shared.recordTTSGenerated(
                backend: backend,
                synthMs: synthMs,
                audioDuration: audioDuration,
                sampleRate: sampleRate,
                byteCount: byteCount,
                textLength: textLength
            )
        }
    }

    static func recordTTSFailed(
        backend: String,
        phase: String,
        reason: String,
        textLength: Int? = nil
    ) {
        Task {
            await TelemetryClient.shared.recordTTSFailed(
                backend: backend,
                phase: phase,
                reason: reason,
                textLength: textLength
            )
        }
    }

    static func recordAudioRoute(reason: String) {
        Task {
            await TelemetryClient.shared.recordAudioRoute(reason: reason)
        }
    }

    static func recordAudioPlayStarted(
        backend: String,
        audioDuration: TimeInterval?,
        sampleRate: Int?
    ) {
        Task {
            await TelemetryClient.shared.recordAudioPlayStarted(
                backend: backend,
                audioDuration: audioDuration,
                sampleRate: sampleRate
            )
        }
    }

    static func recordAudioPlayFinished(
        backend: String,
        outcome: String,
        playbackDuration: TimeInterval?,
        audioDuration: TimeInterval?
    ) {
        Task {
            await TelemetryClient.shared.recordAudioPlayFinished(
                backend: backend,
                outcome: outcome,
                playbackDuration: playbackDuration,
                audioDuration: audioDuration
            )
        }
    }

    static func recordAudioMuted(
        backend: String,
        phase: String
    ) {
        Task {
            await TelemetryClient.shared.recordAudioMuted(
                backend: backend,
                phase: phase
            )
        }
    }

    static func recordAudioInterrupted(
        phase: String,
        shouldResume: Bool? = nil
    ) {
        Task {
            await TelemetryClient.shared.recordAudioInterrupted(
                phase: phase,
                shouldResume: shouldResume
            )
        }
    }

    static func failureReason(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        let nsError = error as NSError
        let domain = nsError.domain
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return "\(domain)_\(nsError.code)"
    }
}

private enum TelemetryAppInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}

actor TelemetryClient {
    static let shared = TelemetryClient()

    static let endpointDefaultsKey = "PhoneClaw.telemetry.endpoint"
    static let tokenDefaultsKey = "PhoneClaw.telemetry.token"

    private static let userIDDefaultsKey = "PhoneClaw.telemetry.userID"
    private static let installIDDefaultsKey = "PhoneClaw.telemetry.installID"
    private static let installCohortDefaultsKey = "PhoneClaw.telemetry.installCohort"
    private static let queueDefaultsKey = "PhoneClaw.telemetry.queue.v1"
    private static let maxQueuedEvents = 500
    private static let maxBatchSize = 50

    private let defaults: UserDefaults
    private var queue: [TelemetryQueuedEvent]
    private var isUploading = false
    private var appSessionID: String?
    private var lastAppOpenAt: Date?
    private var currentSessionID: String?
    private var currentSessionStartedAt: Date?
    private var turnCount = 0
    private var didSendFirstMessage = false
    private var didRecordFirstResponse = false
    private var installStartedAt: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queue = Self.loadQueue(defaults: defaults)
    }

    func recordAppOpen() {
        guard isReady else { return }

        let now = Date()
        if let lastAppOpenAt, now.timeIntervalSince(lastAppOpenAt) < 30 {
            return
        }

        let sessionID = UUID().uuidString
        appSessionID = sessionID
        lastAppOpenAt = now

        enqueue(
            name: "app_open",
            sessionID: sessionID,
            properties: [
                "install_cohort": .string(installCohort)
            ]
        )
    }

    private func startConversationSession() {
        guard isReady, currentSessionID == nil else { return }
        currentSessionID = UUID().uuidString
        currentSessionStartedAt = Date()
        turnCount = 0
        didSendFirstMessage = false
        didRecordFirstResponse = false

        enqueue(
            name: "session_start",
            sessionID: currentSessionID!,
            properties: [
                "install_cohort": .string(installCohort)
            ]
        )
    }

    func endSession() {
        guard isReady, currentSessionID != nil else { return }
        enqueue(
            name: "session_end",
            sessionID: currentSessionID!,
            properties: [
                "turn_count": .int(turnCount),
                "had_second_turn": .bool(turnCount >= 2),
                "duration_bucket": .string(Self.durationBucket(from: currentSessionStartedAt))
            ]
        )
        currentSessionID = nil
        currentSessionStartedAt = nil
        turnCount = 0
        didSendFirstMessage = false
        didRecordFirstResponse = false
        scheduleUpload()
    }

    func recordMessageSent(
        modelID: String,
        modality: TelemetryModality,
        inputLanguage: TelemetryInputLanguage
    ) {
        guard isReady else { return }
        ensureConversationSession()
        turnCount += 1

        guard !didSendFirstMessage else { return }
        didSendFirstMessage = true
        enqueue(
            name: "first_message_sent",
            sessionID: currentSessionID!,
            properties: [
                "model_id": .string(modelID),
                "modality": .string(modality.rawValue),
                "input_language": .string(inputLanguage.rawValue)
            ]
        )
    }

    func recordFirstResponseReceived(
        modelID: String,
        ttftMs: Double,
        success: Bool,
        failureReason: String?
    ) {
        guard isReady, didSendFirstMessage, !didRecordFirstResponse else { return }
        didRecordFirstResponse = true

        var properties: [String: TelemetryValue] = [
            "model_id": .string(modelID),
            "ttft_bucket": .string(Self.latencyBucket(milliseconds: ttftMs)),
            "success": .bool(success)
        ]
        if let failureReason, !failureReason.isEmpty {
            properties["failure_reason"] = .string(Self.safeString(failureReason))
        }
        guard let sessionID = currentSessionID else { return }
        enqueue(name: "first_response_received", sessionID: sessionID, properties: properties)
    }

    func recordModelInstall(
        modelID: String,
        outcome: TelemetryInstallOutcome,
        failureReason: String?
    ) {
        guard isReady else { return }
        let sessionID = eventSessionID()

        if outcome == .started {
            installStartedAt[modelID] = Date()
        }
        var properties: [String: TelemetryValue] = [
            "model_id": .string(modelID),
            "outcome": .string(outcome.rawValue),
            "duration_bucket": .string(durationBucket(forModelID: modelID, outcome: outcome))
        ]
        if let failureReason, !failureReason.isEmpty {
            properties["failure_reason"] = .string(Self.safeString(failureReason))
        }
        enqueue(name: "model_install", sessionID: sessionID, properties: properties)
    }

    func recordTTSStarted(backend: String, textLength: Int) {
        guard isReady else { return }
        enqueue(
            name: "tts_started",
            sessionID: eventSessionID(),
            properties: [
                "backend": .string(Self.safeString(backend)),
                "text_length_bucket": .string(Self.countBucket(textLength))
            ]
        )
    }

    func recordTTSGenerated(
        backend: String,
        synthMs: Double,
        audioDuration: TimeInterval,
        sampleRate: Int,
        byteCount: Int,
        textLength: Int
    ) {
        guard isReady else { return }
        enqueue(
            name: "tts_generated",
            sessionID: eventSessionID(),
            properties: [
                "backend": .string(Self.safeString(backend)),
                "synth_duration_bucket": .string(Self.latencyBucket(milliseconds: synthMs)),
                "audio_duration_bucket": .string(Self.durationBucket(seconds: audioDuration)),
                "sample_rate": .int(sampleRate),
                "byte_count_bucket": .string(Self.countBucket(byteCount)),
                "text_length_bucket": .string(Self.countBucket(textLength))
            ]
        )
    }

    func recordTTSFailed(
        backend: String,
        phase: String,
        reason: String,
        textLength: Int?
    ) {
        guard isReady else { return }
        var properties: [String: TelemetryValue] = [
            "backend": .string(Self.safeString(backend)),
            "phase": .string(Self.safeString(phase)),
            "failure_reason": .string(Self.safeString(reason))
        ]
        if let textLength {
            properties["text_length_bucket"] = .string(Self.countBucket(textLength))
        }
        enqueue(name: "tts_failed", sessionID: eventSessionID(), properties: properties)
    }

    func recordAudioRoute(reason: String) {
        guard isReady else { return }
        enqueue(
            name: "audio_route",
            sessionID: eventSessionID(),
            properties: Self.audioRouteProperties(reason: reason)
        )
    }

    func recordAudioPlayStarted(
        backend: String,
        audioDuration: TimeInterval?,
        sampleRate: Int?
    ) {
        guard isReady else { return }
        var properties = Self.audioRouteProperties(reason: "play_started")
        properties["backend"] = .string(Self.safeString(backend))
        if let audioDuration {
            properties["audio_duration_bucket"] = .string(Self.durationBucket(seconds: audioDuration))
        }
        if let sampleRate {
            properties["sample_rate"] = .int(sampleRate)
        }
        enqueue(name: "audio_play_started", sessionID: eventSessionID(), properties: properties)

        if Self.isAudioMuted {
            recordAudioMuted(backend: backend, phase: "play_started")
        }
    }

    func recordAudioPlayFinished(
        backend: String,
        outcome: String,
        playbackDuration: TimeInterval?,
        audioDuration: TimeInterval?
    ) {
        guard isReady else { return }
        var properties: [String: TelemetryValue] = [
            "backend": .string(Self.safeString(backend)),
            "outcome": .string(Self.safeString(outcome))
        ]
        if let playbackDuration {
            properties["playback_duration_bucket"] = .string(Self.durationBucket(seconds: playbackDuration))
        }
        if let audioDuration {
            properties["audio_duration_bucket"] = .string(Self.durationBucket(seconds: audioDuration))
        }
        enqueue(name: "audio_play_finished", sessionID: eventSessionID(), properties: properties)
    }

    func recordAudioMuted(backend: String, phase: String) {
        guard isReady else { return }
        var properties = Self.audioRouteProperties(reason: phase)
        properties["backend"] = .string(Self.safeString(backend))
        properties["phase"] = .string(Self.safeString(phase))
        enqueue(name: "audio_muted", sessionID: eventSessionID(), properties: properties)
    }

    func recordAudioInterrupted(phase: String, shouldResume: Bool?) {
        guard isReady else { return }
        var properties = Self.audioRouteProperties(reason: phase)
        properties["phase"] = .string(Self.safeString(phase))
        if let shouldResume {
            properties["should_resume"] = .bool(shouldResume)
        }
        enqueue(name: "audio_interrupted", sessionID: eventSessionID(), properties: properties)
    }

    func flush() {
        scheduleUpload()
    }

    private var isReady: Bool {
        endpointURL != nil
    }

    private var endpointURL: URL? {
        if let override = Self.configuredString(defaults.string(forKey: Self.endpointDefaultsKey)),
           let url = URL(string: override) {
            return url
        }

        if let value = Self.configuredString(
            Bundle.main.object(forInfoDictionaryKey: "PhoneClawTelemetryEndpoint") as? String
        ),
           let url = URL(string: value) {
            return url
        }

        #if DEBUG
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8765/v1/events")
        #endif
        #endif

        return nil
    }

    private var authToken: String? {
        if let override = Self.configuredString(defaults.string(forKey: Self.tokenDefaultsKey)) {
            return override
        }
        if let value = Self.configuredString(
            Bundle.main.object(forInfoDictionaryKey: "PhoneClawTelemetryToken") as? String
        ) {
            return value
        }
        return nil
    }

    private static func configuredString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private var installID: String {
        if let existing = defaults.string(forKey: Self.installIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: Self.installIDDefaultsKey)
        return value
    }

    private var userID: String {
        if let existing = defaults.string(forKey: Self.userIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let value = installID
        defaults.set(value, forKey: Self.userIDDefaultsKey)
        return value
    }

    private var installCohort: String {
        if let existing = defaults.string(forKey: Self.installCohortDefaultsKey), !existing.isEmpty {
            return existing
        }
        let value = Self.cohortDay(from: Date())
        defaults.set(value, forKey: Self.installCohortDefaultsKey)
        return value
    }

    private func ensureConversationSession() {
        if currentSessionID == nil {
            startConversationSession()
        }
    }

    private func eventSessionID() -> String {
        if let currentSessionID {
            return currentSessionID
        }
        if let appSessionID {
            return appSessionID
        }
        let sessionID = UUID().uuidString
        appSessionID = sessionID
        return sessionID
    }

    private func enqueue(name: String, sessionID: String, properties: [String: TelemetryValue]) {
        let appVersion = TelemetryAppInfo.appVersion
        let buildNumber = TelemetryAppInfo.buildNumber
        let event = TelemetryQueuedEvent(
            eventID: UUID().uuidString,
            name: name,
            clientTimestamp: Self.isoTimestamp(from: Date()),
            sessionID: sessionID,
            appVersion: appVersion,
            buildNumber: buildNumber,
            properties: properties
        )
        queue.append(event)
        if queue.count > Self.maxQueuedEvents {
            queue.removeFirst(queue.count - Self.maxQueuedEvents)
        }
        persistQueue()
        scheduleUpload()
    }

    private func scheduleUpload() {
        guard endpointURL != nil, !queue.isEmpty else { return }
        Task { await uploadIfNeeded() }
    }

    private func uploadIfNeeded() async {
        guard !isUploading, let endpointURL else { return }
        guard !queue.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }

        let batch = uploadBatch()
        guard let firstEvent = batch.first else { return }
        let payload = TelemetryPayload(
            appID: "phoneclaw-ios",
            userID: userID,
            installID: installID,
            sessionID: currentSessionID ?? batch.first?.sessionID ?? UUID().uuidString,
            appVersion: firstEvent.appVersion,
            build: firstEvent.buildNumber,
            buildNumber: firstEvent.buildNumber,
            deviceModel: Self.deviceModelIdentifier(),
            osVersion: Self.systemVersionString(),
            locale: Locale.current.identifier,
            schemaVersion: 2,
            events: batch.map {
                TelemetryPayload.Event(
                    eventID: $0.eventID,
                    name: $0.name,
                    clientTimestamp: $0.clientTimestamp,
                    sessionID: $0.sessionID,
                    properties: $0.properties
                )
            }
        )

        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let authToken {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }

            let sentIDs = Set(batch.map(\.eventID))
            queue.removeAll { sentIDs.contains($0.eventID) }
            persistQueue()
        } catch {
            return
        }
    }

    private func uploadBatch() -> [TelemetryQueuedEvent] {
        guard let first = queue.first else { return [] }
        var batch: [TelemetryQueuedEvent] = []

        for event in queue {
            guard event.appVersion == first.appVersion,
                  event.buildNumber == first.buildNumber else {
                break
            }
            batch.append(event)
            if batch.count >= Self.maxBatchSize {
                break
            }
        }
        return batch
    }

    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: Self.queueDefaultsKey)
    }

    private func durationBucket(forModelID modelID: String, outcome: TelemetryInstallOutcome) -> String {
        guard outcome != .started, let started = installStartedAt[modelID] else {
            return "unknown"
        }
        let seconds = Date().timeIntervalSince(started)
        installStartedAt[modelID] = nil
        return Self.durationBucket(seconds: seconds)
    }

    private static func loadQueue(defaults: UserDefaults) -> [TelemetryQueuedEvent] {
        guard let data = defaults.data(forKey: queueDefaultsKey),
              let queue = try? JSONDecoder().decode([TelemetryQueuedEvent].self, from: data) else {
            return []
        }
        return Array(queue.suffix(maxQueuedEvents))
    }

    private static func latencyBucket(milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "unknown" }
        let seconds = milliseconds / 1000
        return durationBucket(seconds: seconds)
    }

    private static func durationBucket(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1:
            return "lt_1s"
        case ..<3:
            return "1_3s"
        case ..<10:
            return "3_10s"
        case ..<30:
            return "10_30s"
        case ..<60:
            return "30_60s"
        case ..<300:
            return "1_5m"
        default:
            return "5m_plus"
        }
    }

    private static func durationBucket(from startDate: Date?) -> String {
        guard let startDate else { return "unknown" }
        return durationBucket(seconds: Date().timeIntervalSince(startDate))
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1:
            return "zero"
        case ..<32:
            return "1_31"
        case ..<128:
            return "32_127"
        case ..<512:
            return "128_511"
        case ..<2048:
            return "512_2047"
        default:
            return "2048_plus"
        }
    }

    private static var isAudioMuted: Bool {
        #if canImport(UIKit)
        AVAudioSession.sharedInstance().outputVolume <= 0.01
        #else
        false   // macOS (CLI harness): 无 AVAudioSession
        #endif
    }

    private static func audioRouteProperties(reason: String) -> [String: TelemetryValue] {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }
        let route = outputs.isEmpty ? "none" : outputs.joined(separator: "+")
        let volume = session.outputVolume

        return [
            "reason": .string(safeString(reason)),
            "output_route": .string(safeString(route)),
            "output_count": .int(outputs.count),
            "category": .string(safeString(session.category.rawValue)),
            "mode": .string(safeString(session.mode.rawValue)),
            "volume_bucket": .string(volumeBucket(volume)),
            "muted": .bool(volume <= 0.01)
        ]
        #else
        return ["reason": .string(safeString(reason)), "output_route": .string("macos")]
        #endif
    }

    private static func volumeBucket(_ volume: Float) -> String {
        if volume <= 0.01 {
            return "muted"
        }
        if volume < 0.25 {
            return "low"
        }
        if volume < 0.75 {
            return "medium"
        }
        return "high"
    }

    private static func safeString(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:/+@ -")
        let scalars = value.prefix(96).unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }

    private static func isoTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func cohortDay(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func systemVersionString() -> String {
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

}

private struct TelemetryQueuedEvent: Codable, Sendable {
    let eventID: String
    let name: String
    let clientTimestamp: String
    let sessionID: String
    let appVersion: String
    let buildNumber: String
    let properties: [String: TelemetryValue]

    enum CodingKeys: String, CodingKey {
        case eventID
        case name
        case clientTimestamp
        case sessionID
        case appVersion
        case buildNumber
        case properties
    }

    init(
        eventID: String,
        name: String,
        clientTimestamp: String,
        sessionID: String,
        appVersion: String,
        buildNumber: String,
        properties: [String: TelemetryValue]
    ) {
        self.eventID = eventID
        self.name = name
        self.clientTimestamp = clientTimestamp
        self.sessionID = sessionID
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.properties = properties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        name = try container.decode(String.self, forKey: .name)
        clientTimestamp = try container.decode(String.self, forKey: .clientTimestamp)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? TelemetryAppInfo.appVersion
        buildNumber = try container.decodeIfPresent(String.self, forKey: .buildNumber) ?? TelemetryAppInfo.buildNumber
        properties = try container.decode([String: TelemetryValue].self, forKey: .properties)
    }
}

private struct TelemetryPayload: Encodable, Sendable {
    let appID: String
    let userID: String
    let installID: String
    let sessionID: String
    let appVersion: String
    let build: String
    let buildNumber: String
    let deviceModel: String
    let osVersion: String
    let locale: String
    let schemaVersion: Int
    let events: [Event]

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case userID = "user_id"
        case installID = "install_id"
        case sessionID = "session_id"
        case appVersion = "app_version"
        case build
        case buildNumber = "build_number"
        case deviceModel = "device_model"
        case osVersion = "os_version"
        case locale
        case schemaVersion = "schema_version"
        case events
    }

    struct Event: Encodable, Sendable {
        let eventID: String
        let name: String
        let clientTimestamp: String
        let sessionID: String
        let properties: [String: TelemetryValue]

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case name
            case clientTimestamp = "client_ts"
            case sessionID = "session_id"
            case properties
        }
    }
}

private enum TelemetryValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .string((try? container.decode(String.self)) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}
