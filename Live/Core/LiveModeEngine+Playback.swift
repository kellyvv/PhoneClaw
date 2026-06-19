import Foundation

extension LiveModeEngine {
    // MARK: - Playback Enqueue

    func enqueueForPlayback(_ text: String, generation gen: UInt64) async {
        let cleaned = stripForTTS(text)
        guard !cleaned.isEmpty else { return }

        // Generation guard: don't enqueue if this turn has been superseded
        guard turnGeneration == gen else { return }

        if tts.usesSharedAudioEngine {
            let wavData: Data? = await withTaskGroup(of: Data?.self) { group in
                group.addTask { [tts] in tts.synthesize(cleaned) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    return nil as Data?
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let wavData else {
                print("[Live] ⏱ TTS timeout or empty for: \"\(cleaned.prefix(20))\"")
                return
            }

            // Post-synthesis generation guard: stale turn's audio must not enter new turn's queue
            guard turnGeneration == gen else { return }

            // TTS first chunk metric: stamped AFTER synthesis, not before
            if currentTurnMetrics != nil && currentTurnMetrics!.ttsFirstChunkAt == 0 {
                currentTurnMetrics!.ttsFirstChunkAt = CFAbsoluteTimeGetCurrent()
            }

            await ttsQueue?.enqueueWAV(wavData)
        } else if tts.allowsSystemFallback {
            guard turnGeneration == gen else { return }
            if currentTurnMetrics != nil && currentTurnMetrics!.ttsFirstChunkAt == 0 {
                currentTurnMetrics!.ttsFirstChunkAt = CFAbsoluteTimeGetCurrent()
            }
            await ttsQueue?.enqueueSystemSpeak(cleaned)
        } else {
            print("[Live] ❌ TTS skipped: no non-system TTS backend available")
        }
    }

    func stripForTTS(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "#", with: "")
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "（", with: "")
        s = s.replacingOccurrences(of: "）", with: "")
        s = s.replacingOccurrences(of: "(", with: "")
        s = s.replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: "：", with: "，")
        s = s.replacingOccurrences(of: ":", with: "，")
        s = s.replacingOccurrences(of: "- ", with: "")
        var filteredScalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let value = scalar.value
            if value == 0x200D || (0xFE00...0xFE0F).contains(value) { continue }
            if scalar.properties.isEmojiPresentation { continue }
            if (0x1F000...0x1FAFF).contains(value) { continue }
            filteredScalars.append(scalar)
        }
        s = String(filteredScalars)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speakable Segment Extraction

    private func extractSpeakableSegments(from buffer: String) -> (segments: [String], remainder: String) {
        var segments: [String] = []
        var lastSplit = buffer.startIndex

        let hardChinesePunctuation: Set<Character> = ["。", "！", "？", "；"]
        let softChinesePunctuation: Set<Character> = ["，", "、", "："]
        let hardEnglishPunctuation: Set<Character> = [".", "!", "?", ";"]
        let softEnglishPunctuation: Set<Character> = [",", ":"]
        // minSoftClauseLength: 5 (was 8). 更激进地切逗号 → 首段 chunk 更小 →
        // TTS 合成更快出第一段音频 → TTFS 从 ~2.6s 降到 ~0.8s.
        // 5 个汉字对应约 2-3 个词, 仍然是自然的语调停顿点.
        let minSoftClauseLength = 5

        var i = buffer.startIndex
        while i < buffer.endIndex {
            let ch = buffer[i]
            let nextIdx = buffer.index(after: i)

            var isSplit = false

            if hardChinesePunctuation.contains(ch) || ch == "\n" {
                isSplit = true
            } else if softChinesePunctuation.contains(ch) || softEnglishPunctuation.contains(ch) {
                let clause = String(buffer[lastSplit..<nextIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                isSplit = clause.count >= minSoftClauseLength
            } else if hardEnglishPunctuation.contains(ch) && nextIdx < buffer.endIndex {
                let next = buffer[nextIdx]
                if next == " " || next == "\n" {
                    let clause = String(buffer[lastSplit..<nextIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    isSplit = clause.count >= minSoftClauseLength
                }
            } else if hardEnglishPunctuation.contains(ch) && nextIdx == buffer.endIndex {
                isSplit = true
            }

            if isSplit {
                let segmentEnd = nextIdx
                let segment = String(buffer[lastSplit..<segmentEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !segment.isEmpty {
                    segments.append(segment)
                    lastSplit = segmentEnd
                }
            }

            i = nextIdx
        }

        let remainder = String(buffer[lastSplit...])
        return (segments, remainder)
    }}
