import Foundation
import MLXLMCommon
import Tokenizers

/// Bridges `swift-tokenizers` to `MLXLMCommon.Tokenizer`.
struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch let error as Tokenizers.TokenizerError {
            if case .missingChatTemplate = error {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            throw error
        }
    }
}

struct MLXTokenizersLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // swift-tokenizers 0.2.x 把 from(modelFolder:) 重命名成 from(directory:);
        // Package.resolved bump 之后必须用新名 (iOS 之前缓存里是旧 API 所以编译过)。
        let upstream = try await AutoTokenizer.from(directory: directory)
        return MLXTokenizerBridge(upstream)
    }
}
