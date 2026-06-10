import Foundation

public struct CoreAIFunctionSummary: Codable, Equatable, Sendable {
    public let name: String
    public let descriptorDescription: String

    public init(name: String, descriptorDescription: String) {
        self.name = name
        self.descriptorDescription = descriptorDescription
    }
}

public struct CoreAIProbeResult: Codable, Equatable, Sendable {
    public let modelPath: String
    public let deviceArchitectureName: String?
    public let loadDurationMS: Double
    public let functionSummaries: [CoreAIFunctionSummary]
    public let notes: [String]

    public init(
        modelPath: String,
        deviceArchitectureName: String?,
        loadDurationMS: Double,
        functionSummaries: [CoreAIFunctionSummary],
        notes: [String]
    ) {
        self.modelPath = modelPath
        self.deviceArchitectureName = deviceArchitectureName
        self.loadDurationMS = loadDurationMS
        self.functionSummaries = functionSummaries
        self.notes = notes
    }
}

public struct CoreAIProbe: Sendable {
    public static let betaFlag = "PHONECLAW_IOS27_BETA_SDK"

    public init() {}

    public func availability() -> PlanningModelAvailability {
        #if canImport(CoreAI) && PHONECLAW_IOS27_BETA_SDK
        if #available(iOS 27.0, macOS 27.0, *) {
            return .available
        } else {
            return .unavailable("CoreAI requires iOS 27 or macOS 27.")
        }
        #else
        return .unavailable("CoreAI is not available. Re-run with Xcode 27 and -D\(Self.betaFlag).")
        #endif
    }

    public func inspectModel(at modelURL: URL) async throws -> CoreAIProbeResult {
        #if canImport(CoreAI) && PHONECLAW_IOS27_BETA_SDK
        if #available(iOS 27.0, macOS 27.0, *) {
            return try await inspectModelWithCoreAI(at: modelURL)
        }
        throw IOS27ExperimentError.unavailable("CoreAI requires iOS 27 or macOS 27.")
        #else
        _ = modelURL
        throw IOS27ExperimentError.unavailable("CoreAI is not available in this build.")
        #endif
    }

    public func aotCompileCommand(for modelURL: URL, platform: String = "iOS") -> [String] {
        [
            "xcrun",
            "coreai-build",
            "compile",
            modelURL.path,
            "--platform",
            platform,
        ]
    }
}

#if canImport(CoreAI) && PHONECLAW_IOS27_BETA_SDK
import CoreAI

@available(iOS 27.0, macOS 27.0, *)
private extension CoreAIProbe {
    func inspectModelWithCoreAI(at modelURL: URL) async throws -> CoreAIProbeResult {
        let started = Date()
        let model = try await AIModel(contentsOf: modelURL)
        let elapsed = Date().timeIntervalSince(started) * 1000

        let summaries = model.functionNames.map { name in
            CoreAIFunctionSummary(
                name: name,
                descriptorDescription: String(describing: model.functionDescriptor(for: name))
            )
        }

        return CoreAIProbeResult(
            modelPath: modelURL.path,
            deviceArchitectureName: AIModel.deviceArchitectureName,
            loadDurationMS: elapsed,
            functionSummaries: summaries,
            notes: [
                "AIModel is lightweight; loadFunction(named:) must be benchmarked separately.",
                "Run cold and warm cache measurements before production integration.",
            ]
        )
    }
}
#endif
