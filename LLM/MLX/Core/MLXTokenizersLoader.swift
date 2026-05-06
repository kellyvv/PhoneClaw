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
        // CLI build (SwiftPM, swift-tokenizers DePasqualeOrg 0.2.x) → decode(tokenIds:)
        // iOS Xcode build (swift-transformers huggingface 1.1.9)     → decode(tokens:)
        // 两个包都 export `Tokenizers` 模块名但 API 不兼容. 这个文件是 symlink, 两个 target
        // 编译同一份, 必须用 #if 切. SWIFT_PACKAGE 是 SwiftPM 自动设的 define, Xcode 没有.
        #if SWIFT_PACKAGE
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
        #else
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        #endif
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
        // CLI: AutoTokenizer.from(directory:); iOS: AutoTokenizer.from(modelFolder:).
        // 同上 SWIFT_PACKAGE 切.
        #if SWIFT_PACKAGE
        let upstream = try await AutoTokenizer.from(directory: directory)
        #else
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        #endif
        return MLXTokenizerBridge(upstream)
    }
}
