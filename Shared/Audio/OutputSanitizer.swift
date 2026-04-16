import Foundation

// MARK: - OutputSanitizer (stateless)
//
// Chat UI 和 Live Voice 共用的文本清洗逻辑。
// 两种模式: chatUI 保留 thinking 标记, liveVoice 完全剥离。

private let thinkingOpenMarker = "[[PHONECLAW_THINK]]"
private let thinkingCloseMarker = "[[/PHONECLAW_THINK]]"

enum OutputSanitizer {

    enum Mode {
        case chatUI      // thinking channel → [[PHONECLAW_THINK]]...
        case liveVoice   // strip thinking/tool_call/all tags completely
    }

    /// Sanitize full accumulated buffer. Returns (safe prefix, pending suffix).
    /// Chat UI uses `safe` to replace the entire display text.
    /// `pending` holds text that may still be incomplete (unclosed tags).
    static func sanitize(_ buffer: String, mode: Mode) -> (safe: String, pending: String) {
        guard !buffer.isEmpty else { return ("", "") }

        // 1. Mode-specific channel handling
        var processed: String
        switch mode {
        case .chatUI:
            processed = preserveThinkingChannels(in: buffer)
        case .liveVoice:
            processed = stripThinkingChannels(in: buffer)
        }

        // 2. Strip complete <tool_call>...</tool_call> blocks
        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            processed = regex.stringByReplacingMatches(in: processed, range: NSRange(processed.startIndex..., in: processed), withTemplate: "")
        }

        // 3. Truncate at unclosed <tool_call> (streaming)
        if let tcRange = processed.range(of: "<tool_call>") {
            processed = String(processed[processed.startIndex..<tcRange.lowerBound])
        }

        // 4. Strip end-of-turn tokens
        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = processed.range(of: pat) {
                processed = String(processed[processed.startIndex..<range.lowerBound])
                break
            }
        }

        // 5. Strip remaining ML tags (but not thinking markers in chatUI).
        //    Negative lookahead excludes `channel` tag variants — they're exclusively
        //    handled by stripThinkingChannels above. Otherwise this regex would eat
        //    the open tag mid-stream (before \nthought arrives), exposing the
        //    thinking content to TTS. Reproduced on S03 "我想" baseline.
        if mode == .liveVoice {
            processed = processed.replacingOccurrences(
                of: "<\\|?(?!channel)[/a-z_]+\\|?>",
                with: "",
                options: .regularExpression
            )
        } else {
            // chatUI: strip tags but preserve [[PHONECLAW_THINK]] markers
            processed = stripMLTagsPreservingMarkers(processed)
        }

        // 6. Strip role prefixes
        processed = stripRolePrefixes(processed)

        // 7. Handle pending (unclosed tag at end)
        let (safe, pending) = splitPending(processed)

        return (safe, pending)
    }

    /// Final clean - stream ended, no more tokens coming.
    static func sanitizeFinal(_ buffer: String, mode: Mode) -> String {
        let (safe, _) = sanitize(buffer, mode: mode)
        // On finalize, the pending part is just incomplete junk - drop it
        return safe.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    /// Chat UI: convert <|channel|>thought\n...<channel|> to [[PHONECLAW_THINK]]...[[/PHONECLAW_THINK]]
    private static func preserveThinkingChannels(in text: String) -> String {
        let openTokens = ["<|channel|>thought\n", "<|channel>thought\n"]
        let closeToken = "<channel|>"

        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let nextOpen = openTokens
                .compactMap { token -> (Range<String.Index>, String)? in
                    guard let range = text.range(of: token, range: cursor..<text.endIndex) else {
                        return nil
                    }
                    return (range, token)
                }
                .min(by: { $0.0.lowerBound < $1.0.lowerBound })

            guard let (openRange, token) = nextOpen else {
                result += text[cursor..<text.endIndex]
                break
            }

            result += text[cursor..<openRange.lowerBound]
            result += thinkingOpenMarker

            let contentStart = text.index(openRange.lowerBound, offsetBy: token.count)
            if let closeRange = text.range(of: closeToken, range: contentStart..<text.endIndex) {
                result += text[contentStart..<closeRange.lowerBound]
                result += thinkingCloseMarker
                cursor = closeRange.upperBound
            } else {
                // Unclosed thinking block - include content, will be in pending
                result += text[contentStart..<text.endIndex]
                break
            }
        }

        return result
    }

    /// Live Voice: strip `<|?channel|?>thought\n...<|?channel|?>` content entirely.
    ///
    /// Handles all 4 open/close variants observed from Gemma 4:
    ///   open:  `<|channel|>thought\n`   `<|channel>thought\n`   `<channel|>thought\n`   `<channel>thought\n`
    ///   close: `<channel|>`             `<|channel|>`           `<channel>`             `<|channel>`
    ///
    /// Streaming-safe: when the open tag is partial (e.g. `<|channe`), the sanitizer
    /// step-5 regex is configured to NOT match channel tags, so they aren't exposed
    /// before we see the full `thought\n` suffix.
    private static func stripThinkingChannels(in text: String) -> String {
        // Find open pattern <|?channel|?>thought\n anywhere
        guard let openRegex = try? NSRegularExpression(
            pattern: "<\\|?channel\\|?>thought\\n",
            options: []
        ),
        let closeRegex = try? NSRegularExpression(
            pattern: "<\\|?channel\\|?>",
            options: []
        ) else {
            return text
        }

        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let searchRange = NSRange(cursor..<text.endIndex, in: text)
            guard let openMatch = openRegex.firstMatch(
                in: text, options: [], range: searchRange
            ) else {
                result += text[cursor..<text.endIndex]
                break
            }
            guard let openSwiftRange = Range(openMatch.range, in: text) else {
                result += text[cursor..<text.endIndex]
                break
            }

            // Append everything before the open tag
            result += text[cursor..<openSwiftRange.lowerBound]

            // Look for matching close AFTER the open's end
            let contentStart = openSwiftRange.upperBound
            let closeSearch = NSRange(contentStart..<text.endIndex, in: text)
            if let closeMatch = closeRegex.firstMatch(
                in: text, options: [], range: closeSearch
            ),
               let closeSwiftRange = Range(closeMatch.range, in: text) {
                cursor = closeSwiftRange.upperBound
            } else {
                // Unclosed thinking block — drop everything from open to end.
                // Matches streaming case where the stream ended mid-thought.
                break
            }
        }

        return result
    }

    /// Strip ML tags but preserve [[PHONECLAW_THINK]] markers
    private static func stripMLTagsPreservingMarkers(_ text: String) -> String {
        // Temporarily replace markers
        var result = text
            .replacingOccurrences(of: thinkingOpenMarker, with: "\u{FFFE}THINK_OPEN\u{FFFE}")
            .replacingOccurrences(of: thinkingCloseMarker, with: "\u{FFFE}THINK_CLOSE\u{FFFE}")

        // Strip ML tags
        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        // Restore markers
        result = result
            .replacingOccurrences(of: "\u{FFFE}THINK_OPEN\u{FFFE}", with: thinkingOpenMarker)
            .replacingOccurrences(of: "\u{FFFE}THINK_CLOSE\u{FFFE}", with: thinkingCloseMarker)

        return result
    }

    /// Strip "model\n" / "user\n" role prefixes
    private static func stripRolePrefixes(_ text: String) -> String {
        var result = text
        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            return ""
        } else if result.hasPrefix("user\n") {
            result = String(result.dropFirst(5))
        } else if result == "user" {
            return ""
        }
        result = String(result.drop(while: { $0.isWhitespace || $0.isNewline }))
        return result
    }

    /// Split text into (safe, pending) at last unclosed tag marker.
    /// Only holds text that looks like an actual ML tag/marker prefix,
    /// not bare '<' in normal content like '1 < 2'.
    private static func splitPending(_ text: String) -> (safe: String, pending: String) {
        // 1. Check for unclosed [[ marker (thinking)
        if let lastBracket = text.range(of: "[[", options: .backwards) {
            let tail = String(text[lastBracket.lowerBound...])
            if !tail.contains("]]") {
                return (String(text[text.startIndex..<lastBracket.lowerBound]), tail)
            }
        }

        // 2. Check for unclosed < that matches a known ML tag prefix.
        //    Only these specific prefixes are held as pending;
        //    generic text like x<y, Array<String passes through.
        let knownTagPrefixes = [
            "<|channel",   // <|channel|>thought\n
            "<|",          // <|turn>, <|...|>
            "</tool_call", // </tool_call>
            "<tool_call",  // <tool_call>
            "</",          // any closing tag
            "<turn",       // <turn|>
            "<end_",       // <end_of_turn>
            "<eos",        // <eos>
            "<channel",    // <channel|>
        ]
        if let lastAngle = text.range(of: "<", options: .backwards) {
            let tail = String(text[lastAngle.lowerBound...])
            if !tail.contains(">") {
                let matchesKnown = knownTagPrefixes.contains { prefix in
                    tail.hasPrefix(prefix) || prefix.hasPrefix(tail)
                    // prefix.hasPrefix(tail): tail is a partial prefix being built up
                    // e.g. tail="<to" matches prefix="<tool_call" (still typing)
                }
                if matchesKnown {
                    return (String(text[text.startIndex..<lastAngle.lowerBound]), tail)
                }
            }
        }

        return (text, "")
    }
}

// MARK: - StreamingSanitizer (stateful, incremental)
//
// Tracks how far we've released, only returns the new delta.
// Live Voice appends delta to sentenceBuffer for splitting.

struct StreamingSanitizer {
    private let mode: OutputSanitizer.Mode
    private var lastReleasedLength: Int = 0

    init(mode: OutputSanitizer.Mode) { self.mode = mode }

    /// Feed full accumulated buffer, get back only the newly released text.
    mutating func feed(_ fullBuffer: String) -> String {
        let (safe, _) = OutputSanitizer.sanitize(fullBuffer, mode: mode)
        guard safe.count > lastReleasedLength else { return "" }
        let delta = String(safe.dropFirst(lastReleasedLength))
        lastReleasedLength = safe.count
        return delta
    }

    /// Stream ended, release all remaining text.
    mutating func finalize(_ fullBuffer: String) -> String {
        let final = OutputSanitizer.sanitizeFinal(fullBuffer, mode: mode)
        guard final.count > lastReleasedLength else { return "" }
        let delta = String(final.dropFirst(lastReleasedLength))
        lastReleasedLength = final.count
        return delta
    }
}
