import Foundation

public struct BenchmarkRecord: Codable, Equatable, Sendable {
    public let name: String
    public let deviceModel: String
    public let osBuild: String
    public let xcodeBuild: String
    public let modelIdentifier: String
    public let backend: String
    public let coldRun: Bool
    public let loadDurationMS: Double?
    public let firstOutputDurationMS: Double?
    public let peakMemoryMB: Double?
    public let notes: [String]

    public init(
        name: String,
        deviceModel: String,
        osBuild: String,
        xcodeBuild: String,
        modelIdentifier: String,
        backend: String,
        coldRun: Bool,
        loadDurationMS: Double? = nil,
        firstOutputDurationMS: Double? = nil,
        peakMemoryMB: Double? = nil,
        notes: [String] = []
    ) {
        self.name = name
        self.deviceModel = deviceModel
        self.osBuild = osBuild
        self.xcodeBuild = xcodeBuild
        self.modelIdentifier = modelIdentifier
        self.backend = backend
        self.coldRun = coldRun
        self.loadDurationMS = loadDurationMS
        self.firstOutputDurationMS = firstOutputDurationMS
        self.peakMemoryMB = peakMemoryMB
        self.notes = notes
    }
}
