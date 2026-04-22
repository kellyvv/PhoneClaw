#if DEBUG
import Foundation
import PhoneClawEngine

// MARK: - Audio Bypass Test
//
// 绕开 AgentEngine / AttachmentPipeline / OutputSanitizer / Router，
// 直接用 LiteRTLMEngine 的 audio API 跑一个已知 MP3，验证模型真实输出。
//
// 目的: 对比 engine.audio() (非流式) 和 engine.audioStreaming() (App 在用的流式),
// 若非流式输出丰富而流式稀薄 → 坐实 streaming callback 丢 chunk。
//
// 触发: 设置环境变量 PHONECLAW_AUDIO_TEST=1
// (Edit Scheme → Run → Arguments → Environment Variables)

enum AudioBypassTest {
    static let testAudioPath = "/Users/zxw/Downloads/test.mp3"
    static let testPrompt = "请详细描述这段音频的内容，包括是什么类型、说了什么、有什么声音特征。"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["PHONECLAW_AUDIO_TEST"] == "1" else {
            return
        }
        Task.detached(priority: .utility) { await run() }
    }

    static func run() async {
        print("=====================================")
        print("[AudioBypass] START")
        print("=====================================")

        guard let modelPath = resolveModelPath() else {
            print("[AudioBypass] ❌ 找不到已安装的 .litertlm 模型 (查 Documents/models/)")
            return
        }
        print("[AudioBypass] model=\(modelPath.lastPathComponent)")

        let audioURL = URL(fileURLWithPath: testAudioPath)
        guard FileManager.default.fileExists(atPath: testAudioPath) else {
            print("[AudioBypass] ❌ 找不到测试音频: \(testAudioPath)")
            return
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            print("[AudioBypass] ❌ 读取音频失败: \(error)")
            return
        }
        print("[AudioBypass] audio bytes=\(audioData.count)")

        let engine = LiteRTLMEngine(modelPath: modelPath, backend: "cpu")
        do {
            let loadStart = Date()
            try await engine.load()
            let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
            print("[AudioBypass] ✅ engine loaded in \(loadMs)ms")
        } catch {
            print("[AudioBypass] ❌ engine load failed: \(error)")
            return
        }

        await runNonStreaming(engine: engine, audio: audioData)
        await runStreaming(engine: engine, audio: audioData)

        print("=====================================")
        print("[AudioBypass] DONE")
        print("=====================================")
    }

    private static func runNonStreaming(engine: LiteRTLMEngine, audio: Data) async {
        print("")
        print("--- A. engine.audio() NON-STREAMING ---")
        let start = Date()
        do {
            let text = try await engine.audio(
                audioData: audio,
                prompt: testPrompt,
                format: .mp3,
                temperature: 0.7,
                maxTokens: 1024
            )
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[AudioBypass] non-stream elapsed=\(ms)ms length=\(text.count) chars")
            print("[AudioBypass] non-stream output ⬇️")
            print(text.isEmpty ? "<empty>" : text)
        } catch {
            print("[AudioBypass] ❌ non-stream failed: \(error)")
        }
    }

    private static func runStreaming(engine: LiteRTLMEngine, audio: Data) async {
        print("")
        print("--- B. engine.audioStreaming() STREAMING (App path) ---")
        let start = Date()
        var chunks = 0
        var firstChunkMs = -1
        var full = ""
        do {
            for try await chunk in engine.audioStreaming(
                audioData: audio,
                prompt: testPrompt,
                format: .mp3,
                temperature: 0.7,
                maxTokens: 1024
            ) {
                if chunks == 0 {
                    firstChunkMs = Int(Date().timeIntervalSince(start) * 1000)
                }
                chunks += 1
                full += chunk
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("[AudioBypass] stream elapsed=\(ms)ms ttft=\(firstChunkMs)ms chunks=\(chunks) length=\(full.count) chars")
            print("[AudioBypass] stream output ⬇️")
            print(full.isEmpty ? "<empty>" : full)
        } catch {
            print("[AudioBypass] ❌ stream failed: \(error)")
        }
    }

    private static func resolveModelPath() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = docs.appendingPathComponent("models", isDirectory: true)
        for name in ["gemma-4-E2B-it.litertlm", "gemma-4-E4B-it.litertlm"] {
            let url = modelsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Fallback: bundle
        for base in ["gemma-4-E2B-it", "gemma-4-E4B-it"] {
            if let url = Bundle.main.url(forResource: base, withExtension: "litertlm") {
                return url
            }
        }
        return nil
    }
}
#endif
