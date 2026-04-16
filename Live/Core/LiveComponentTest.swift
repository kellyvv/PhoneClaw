import Foundation

// MARK: - Live Component Test
//
// 临时测试: 模型加载后自动跑 VAD + TTS 验证。
// VAD: 监听 5 秒, 打印 speech start/end 事件。
// TTS: 合成一句中文, 从扬声器播出。
// 验证完成后删除此文件。

enum LiveComponentTest {

    /// TTS + VAD 测试 (模型加载前, 避免内存压力)
    static func runTTSOnly() async {
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] TTS + VAD Test")
        print("[LiveTest] ════════════════════════════════════")

        let io = LiveAudioIO()
        do { try io.start() } catch {
            print("[LiveTest] ❌ AudioIO error: \(error)")
            return
        }

        // ── TTS ──
        print("[LiveTest]")
        print("[LiveTest] Step 1: TTS")
        let tts = TTSService()
        tts.audioIO = io
        await tts.initialize()

        if tts.isAvailable {
            await tts.speak("你好，我是 PhoneClaw。请对着手机说话测试语音检测。")
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if tts.state != .speaking { break }
            }
            print("[LiveTest] TTS ✅")
        } else {
            print("[LiveTest] TTS ❌")
        }

        // ── VAD ──
        print("[LiveTest]")
        print("[LiveTest] Step 2: VAD — 监听 10 秒, 请说话")
        let vad = VADService()
        await vad.initialize()

        if vad.isAvailable {
            vad.onSpeechStart = {
                print("[LiveTest] 🎤 Speech START")
            }
            vad.onSpeechEnd = { samples in
                let dur = Double(samples.count) / 16000.0
                print("[LiveTest] 🔇 Speech END (\(String(format: "%.1f", dur))s)")
            }

            await vad.startListening(audioIO: io)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            vad.stopListening()
            print("[LiveTest] VAD ✅")
        } else {
            print("[LiveTest] VAD ❌")
        }

        tts.cleanup()
        io.stop()
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] DONE")
        print("[LiveTest] ════════════════════════════════════")
    }

    /// E2E Live loop: VAD → Gemma 4 ASR+LLM → TTS, 30 秒测试
    static func runLiveLoop(llm: MLXLocalLLMService) async {
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] Live Loop E2E Test (30 seconds)")
        print("[LiveTest] ════════════════════════════════════")

        let engine = LiveModeEngine()
        engine.setup(llm: llm)
        await engine.start()

        // Run for 30 seconds
        print("[LiveTest] Running for 30 seconds — speak to the phone!")
        try? await Task.sleep(nanoseconds: 30_000_000_000)

        await engine.stop()
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] Live Loop DONE")
        print("[LiveTest] ════════════════════════════════════")
    }

    static func run() async {
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] VAD + TTS Component Test")
        print("[LiveTest] ════════════════════════════════════")

        let io = LiveAudioIO()
        do { try io.start() } catch {
            print("[LiveTest] ❌ AudioIO error: \(error)")
            return
        }

        // ── TTS Test ──
        print("[LiveTest]")
        print("[LiveTest] Step 1: TTS — 合成中文语音")
        let tts = TTSService()
        tts.audioIO = io
        await tts.initialize()

        if tts.isAvailable {
            print("[LiveTest] TTS ready, speaking...")
            await tts.speak("你好，我是 PhoneClaw，一个运行在你手机上的 AI 助手。")
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if tts.state != .speaking { break }
            }
            print("[LiveTest] TTS test done")
        } else {
            print("[LiveTest] ❌ TTS not available")
        }

        // ── VAD Test ──
        print("[LiveTest]")
        print("[LiveTest] Step 2: VAD — 监听 10 秒, 请对着手机说话")
        let vad = VADService()
        await vad.initialize()

        if vad.isAvailable {
            vad.onSpeechStart = {
                print("[LiveTest] 🎤 VAD: speech START detected")
            }
            vad.onSpeechEnd = { samples in
                let duration = Double(samples.count) / 16000.0
                print("[LiveTest] 🔇 VAD: speech END (\(String(format: "%.1f", duration))s recorded)")
            }

            await vad.startListening(audioIO: io)
            print("[LiveTest] VAD listening for 10 seconds...")

            try? await Task.sleep(nanoseconds: 10_000_000_000)

            vad.stopListening()
            print("[LiveTest] VAD test done")
        } else {
            print("[LiveTest] ❌ VAD not available")
        }

        tts.cleanup()
        io.stop()
        print("[LiveTest]")
        print("[LiveTest] ════════════════════════════════════")
        print("[LiveTest] ALL TESTS DONE")
        print("[LiveTest] ════════════════════════════════════")
    }
}
