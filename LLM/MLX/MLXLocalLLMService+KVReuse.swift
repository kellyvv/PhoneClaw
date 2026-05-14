import Foundation
import MLX
import MLXLMCommon

// MARK: - KV Reuse Benchmark
//
// 框架级 cache reuse 聚合统计 (顶层 enum, 跨模块可访问).
// CLI ScenarioRunner 在每个 scenario 前后调 reset/snapshot 收集数据, 用来
// 对比不同 prompt 设计下的 token 消耗 + 命中率. iOS UI 不读, 0 行为影响.
public enum KVReuseBenchmark {
    public private(set) static var totalPromptTokens: Int = 0
    public private(set) static var totalCommonTokens: Int = 0
    public private(set) static var totalDeltaTokens: Int = 0
    public private(set) static var turnCount: Int = 0
    public private(set) static var freshCacheCount: Int = 0

    public static func reset() {
        totalPromptTokens = 0
        totalCommonTokens = 0
        totalDeltaTokens = 0
        turnCount = 0
        freshCacheCount = 0
    }

    static func record(promptTokens: Int, commonPrefix: Int, deltaTokens: Int, isFresh: Bool) {
        totalPromptTokens += promptTokens
        totalCommonTokens += commonPrefix
        totalDeltaTokens += deltaTokens
        turnCount += 1
        if isFresh { freshCacheCount += 1 }
    }

    public static var hitRatePercent: Int {
        totalPromptTokens == 0 ? 0 : Int(round(Double(totalCommonTokens) * 100 / Double(totalPromptTokens)))
    }
}

// MARK: - KV Cache Reuse
//
// Cross-turn prompt prefix caching for text-only inference.
//
// Gemma 4 E4B re-prefills the entire prompt every generateStream call, which at
// Phase 2 skill-expanded prompt size (~400 tok system + turn history) costs
// ~200ms TTFT per turn. Python probe (phoneclaw_probe/kv_reuse_multi.py) measured
// a 1.9x speedup (355ms → 182ms) by holding one KVCache across turns and only
// prefilling the delta since the last call.
//
// Strategy:
// 1. Service holds one `activeCache` + `cachedPromptTokens` (IDs processed into cache)
// 2. On each text-only generateStream:
//    a. Tokenize via processor (unchanged path)
//    b. Diff new prompt tokens vs cached → common prefix length
//    c. Trim cache to commonPrefix, feed only delta tokens via generate(cache:)
// 3. After generation, trim cache back to the prompt length so the next diff
//    is based on the exact prompt content (not mixed with generated tokens,
//    whose IDs may not match the retokenized assistant reply on the next turn).
//
// Scope:
// - Text-only path only. Multimodal (images/audio) bypasses cache reuse entirely
//   because image tokens get replaced with embeddings downstream.
// - Cache is invalidated on: model load/unload, multimodal call, generation
//   cancellation, or any error during generation.
// - Feature flag `kvReuseEnabled` defaults true; harness/tests can flip it off
//   to verify cache-on vs cache-off parity.

extension MLXLocalLLMService {

    /// Decision produced by the cache-reuse planner for one call.
    struct KVReusePlan {
        let cache: [KVCache]
        let deltaInput: LMInput
        let fullPromptTokens: [Int]
        let commonPrefix: Int
        let isFreshCache: Bool
    }

    /// Plan a cache-reuse path for the given prepared input.
    ///
    /// Returns nil if reuse is disabled or not applicable; callers should fall
    /// back to the no-cache path in that case.
    func planKVReuse(
        preparedInput: LMInput,
        model: any LanguageModel,
        parameters: GenerateParameters,
        isMultimodal: Bool
    ) -> KVReusePlan? {
        guard kvReuseEnabled, !isMultimodal else { return nil }
        // Text-only path: flatten to 1D Int array
        let tokensArray = preparedInput.text.tokens
        // Expected shape [1, S]; fall back to whatever asArray yields
        let flatTokens: [Int] = tokensArray.asArray(Int.self)
        guard !flatTokens.isEmpty else { return nil }

        var commonPrefix = 0
        if let cache = activeCache {
            let maxCompare = min(cachedPromptTokens.count, flatTokens.count)
            var i = 0
            while i < maxCompare && cachedPromptTokens[i] == flatTokens[i] {
                i += 1
            }
            commonPrefix = i
            // Need at least 1 new token to feed; if new prompt is identical
            // or is a prefix of the cached one, invalidate and take fresh path.
            if commonPrefix >= flatTokens.count || commonPrefix == 0 {
                invalidateKVReuseCache()
                return buildFreshPlan(
                    flatTokens: flatTokens,
                    model: model,
                    parameters: parameters
                )
            }
            // Trim cache to the reuse boundary
            let excess = cache[0].offset - commonPrefix
            if excess > 0 {
                _ = trimPromptCache(cache, numTokens: excess)
            }
            let deltaIds = Array(flatTokens[commonPrefix...])
            let deltaInput = makeLMInput(fromTokens: deltaIds)
            // 命中率 = common / new — 高命中率意味着这个 prompt 跟上一个 prompt
                // 共享 token 多, KV cache 复用收益大. <50% 通常说明 prompt 结构在
                // 跨 turn 之间变化大 (例如不同 SKILL body / system 块换 lean 等),
                // 应该回查 PromptBuilder 是不是没保持结构稳定.
            let hitRate = flatTokens.isEmpty ? 0 : Int(round(Double(commonPrefix) * 100 / Double(flatTokens.count)))
            PCLog.debug(
                "[MLX] KV reuse — cached=\(cachedPromptTokens.count)t "
                    + "new=\(flatTokens.count)t common=\(commonPrefix)t "
                    + "delta=\(deltaIds.count)t hit=\(hitRate)%"
            )
            KVReuseBenchmark.record(promptTokens: flatTokens.count, commonPrefix: commonPrefix, deltaTokens: deltaIds.count, isFresh: false)
            return KVReusePlan(
                cache: cache,
                deltaInput: deltaInput,
                fullPromptTokens: flatTokens,
                commonPrefix: commonPrefix,
                isFreshCache: false
            )
        }

        return buildFreshPlan(
            flatTokens: flatTokens,
            model: model,
            parameters: parameters
        )
    }

    private func buildFreshPlan(
        flatTokens: [Int],
        model: any LanguageModel,
        parameters: GenerateParameters
    ) -> KVReusePlan {
        let newCache = model.newCache(parameters: parameters)
        let fullInput = makeLMInput(fromTokens: flatTokens)
        PCLog.debug("[MLX] KV reuse — fresh cache, prompt=\(flatTokens.count)t")
        KVReuseBenchmark.record(promptTokens: flatTokens.count, commonPrefix: 0, deltaTokens: flatTokens.count, isFresh: true)
        return KVReusePlan(
            cache: newCache,
            deltaInput: fullInput,
            fullPromptTokens: flatTokens,
            commonPrefix: 0,
            isFreshCache: true
        )
    }

    /// Commit a successful generation: persist cache and the prompt tokens it
    /// corresponds to. Also trim any generated-token state out of the cache so
    /// the next diff starts from the exact prompt boundary.
    func commitKVReuse(plan: KVReusePlan) {
        // Drop generated tokens' K/V: cache currently has
        //   [commonPrefix tokens from before] + [delta prompt tokens] + [generated tokens]
        // We want cache to end at fullPromptTokens.count.
        let targetLen = plan.fullPromptTokens.count
        let excess = plan.cache[0].offset - targetLen
        if excess > 0 {
            _ = trimPromptCache(plan.cache, numTokens: excess)
        }
        activeCache = plan.cache
        cachedPromptTokens = plan.fullPromptTokens
        logKVCacheBytes(plan.cache, promptTokens: targetLen)
    }

    /// Log KV-cache memory footprint (effective bytes across all layers/arrays).
    /// Useful for comparing fp16 baseline vs 4/8-bit quantized cache.
    private func logKVCacheBytes(_ caches: [KVCache], promptTokens: Int) {
        var totalBytes = 0
        var quantLayers = 0
        for cache in caches {
            if cache is QuantizedKVCacheProtocol { quantLayers += 1 }
            for arr in cache.state {
                totalBytes += arr.nbytes
            }
        }
        let kb = totalBytes / 1024
        let tag = quantLayers > 0 ? "quant=\(quantLayers)/\(caches.count)" : "fp16"
        PCLog.debug("[MLX] KV cache bytes — \(kb) KB across \(caches.count) layers (\(tag), prompt=\(promptTokens)t)")
    }

    /// Drop any cached state. Call on model reload, cancellation, multimodal
    /// entry, or any error path where cache correctness is uncertain.
    func invalidateKVReuseCache() {
        if activeCache != nil {
            PCLog.debug("[MLX] KV reuse — cache invalidated")
        }
        activeCache = nil
        cachedPromptTokens = []
    }

    private func makeLMInput(fromTokens tokens: [Int]) -> LMInput {
        let ids = tokens.map { Int32($0) }
        let array = MLXArray(ids).reshaped([1, ids.count])
        return LMInput(text: .init(tokens: array))
    }
}
