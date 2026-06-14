import Foundation

final class LiveWarmPool {
    static let shared = LiveWarmPool()

    private let engine = LiveModeEngine()
    private var prewarmTask: Task<Void, Never>?

    private init() {}

    func checkout(
        inference: InferenceService,
        userSystemPrompt: String?,
        agentEngine: AgentEngine
    ) -> LiveModeEngine {
        prewarmTask?.cancel()
        prewarmTask = nil
        engine.setup(inference: inference, agentEngine: agentEngine)
        engine.userSystemPrompt = userSystemPrompt
        return engine
    }

    func prewarmIfPossible(inference: InferenceService, userSystemPrompt: String?) {
        guard LiveModelDefinition.isAvailable, inference.isLoaded else { return }
        guard prewarmTask == nil else { return }

        engine.userSystemPrompt = userSystemPrompt

        prewarmTask = Task { [weak self, engine] in
            await engine.prewarmVoiceStack()
            guard !Task.isCancelled else { return }
            self?.prewarmTask = nil
        }
    }
}
