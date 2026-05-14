import Foundation

// MARK: - Prompt Token Estimator
//
// 中英文混合 prompt 的 token 估算。基于 SentencePiece (Gemma 4 用) 在中英文
// 混合内容上的统计:
//   - CJK 字符: ~1.5 chars/token (汉字单字常占 1-2 token)
//   - 拉丁/数字/标点: ~4.0 chars/token (BPE 合并后的常见词)
//
// Plan §九 Phase 3 提出"中文 ~1.5 字/token"。这里取折中:
// 把 prompt 按 unicode scalar 类别加权累加。误差 ±15%,够 context budget 预算用。
//
// 独立文件以便 Tests/ 直接 symlink 单元测试,不拖入 ChatMessage 等更大依赖。

public enum PromptTokenEstimator {

    /// 估算 prompt 的 token 数。最小返回 1。
    public static func estimate(_ prompt: String) -> Int {
        guard !prompt.isEmpty else { return 1 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in prompt.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        let cjkTokens = Double(cjkCount) / 1.5
        let otherTokens = Double(otherCount) / 4.0
        return max(1, Int((cjkTokens + otherTokens).rounded(.up)))
    }

    /// CJK 范围: 主要汉字 + 假名 + 韩文 + 全角标点。
    /// 这些字符在 SentencePiece BPE 中通常 1-2 token,远低于拉丁文的 4 字/token。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3000...0x303F).contains(v)   // CJK Symbols and Punctuation
            || (0x3040...0x309F).contains(v)   // Hiragana
            || (0x30A0...0x30FF).contains(v)   // Katakana
            || (0x3400...0x4DBF).contains(v)   // CJK Unified Ideographs Ext A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs (主)
            || (0xAC00...0xD7AF).contains(v)   // Hangul Syllables
            || (0xF900...0xFAFF).contains(v)   // CJK Compatibility Ideographs
            || (0xFF00...0xFFEF).contains(v)   // Halfwidth and Fullwidth Forms
            || (0x20000...0x2A6DF).contains(v) // CJK Unified Ideographs Ext B
    }
}
