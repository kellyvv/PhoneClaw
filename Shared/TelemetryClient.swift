import Foundation

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

enum Telemetry {
    static func startSession() {
        Task { await TelemetryClient.shared.startSession() }
    }

    static func endSession() {
        Task { await TelemetryClient.shared.endSession() }
    }

    static func flush() {
        Task { await TelemetryClient.shared.flush() }
    }

    static func recordMessageSent(modelID: String, modality: TelemetryModality) {
        Task {
            await TelemetryClient.shared.recordMessageSent(
                modelID: modelID,
                modality: modality
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

    func startSession() {
        guard isReady else { return }
        guard currentSessionID == nil else { return }
        currentSessionID = UUID().uuidString
        currentSessionStartedAt = Date()
        turnCount = 0
        didSendFirstMessage = false
        didRecordFirstResponse = false

        enqueue(
            name: "session_start",
            properties: [
                "install_cohort": .string(installCohort)
            ]
        )
    }

    func endSession() {
        guard isReady, currentSessionID != nil else { return }
        enqueue(
            name: "session_end",
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

    func recordMessageSent(modelID: String, modality: TelemetryModality) {
        guard isReady else { return }
        ensureSession()
        turnCount += 1

        guard !didSendFirstMessage else { return }
        didSendFirstMessage = true
        enqueue(
            name: "first_message_sent",
            properties: [
                "model_id": .string(modelID),
                "modality": .string(modality.rawValue)
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
        enqueue(name: "first_response_received", properties: properties)
    }

    func recordModelInstall(
        modelID: String,
        outcome: TelemetryInstallOutcome,
        failureReason: String?
    ) {
        guard isReady else { return }
        ensureSession()

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
        enqueue(name: "model_install", properties: properties)
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

    private func ensureSession() {
        if currentSessionID == nil {
            startSession()
        }
    }

    private func enqueue(name: String, properties: [String: TelemetryValue]) {
        guard let sessionID = currentSessionID else { return }
        let event = TelemetryQueuedEvent(
            eventID: UUID().uuidString,
            name: name,
            clientTimestamp: Self.isoTimestamp(from: Date()),
            sessionID: sessionID,
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

        let batch = Array(queue.prefix(Self.maxBatchSize))
        let payload = TelemetryPayload(
            appID: "phoneclaw-ios",
            userID: userID,
            installID: installID,
            sessionID: currentSessionID ?? batch.first?.sessionID ?? UUID().uuidString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            deviceModel: Self.deviceModelIdentifier(),
            osVersion: Self.systemVersionString(),
            locale: Locale.current.identifier,
            schemaVersion: 1,
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
    let properties: [String: TelemetryValue]
}

private struct TelemetryPayload: Encodable, Sendable {
    let appID: String
    let userID: String
    let installID: String
    let sessionID: String
    let appVersion: String
    let build: String
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
