import Foundation
import AVFoundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Tokenizers

// MARK: - Audio Test CLI
//
// 最小路径: MP3 → PCM → MLX Gemma 4 → 文本输出
// 用法: swift run AudioTest [e2b|e4b] [audio path] ["prompt"]

struct CLITokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: additionalContext
        )
    }
}

struct CLITokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        CLITokenizerBridge(try await AutoTokenizer.from(directory: directory))
    }
}

// MARK: - Audio Decoding

func decodeToMonoFloat(url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "AudioTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
    }
    try file.read(into: buffer)

    let channelCount = Int(format.channelCount)
    let frameLength = Int(buffer.frameLength)
    guard let channelData = buffer.floatChannelData else {
        throw NSError(domain: "AudioTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "no float channel data"])
    }

    if channelCount == 1 {
        return (
            Array(UnsafeBufferPointer(start: channelData[0], count: frameLength)),
            format.sampleRate
        )
    }
    var samples = Array(repeating: Float(0), count: frameLength)
    let scale = 1.0 / Float(channelCount)
    for ch in 0..<channelCount {
        let ptr = channelData[ch]
        for i in 0..<frameLength {
            samples[i] += ptr[i] * scale
        }
    }
    return (samples, format.sampleRate)
}

// MARK: - Main

@MainActor
func main() async {
    let args = CommandLine.arguments

    var modelTag = "e2b"
    var audioPath = "/Users/zxw/Downloads/test.mp3"
    var prompt = "请详细描述这段音频的内容，包括是什么类型、说了什么、有什么声音特征。"

    var rest = Array(args.dropFirst())
    if let first = rest.first, first == "e2b" || first == "e4b" {
        modelTag = first
        rest.removeFirst()
    }
    if let path = rest.first, !path.isEmpty {
        audioPath = path
        rest.removeFirst()
    }
    if let p = rest.first, !p.isEmpty {
        prompt = p
    }

    let modelDir = modelTag == "e4b" ? "gemma-4-e4b-it-4bit" : "gemma-4-e2b-it-4bit"
    let modelPath = URL(fileURLWithPath: "/Users/zxw/AITOOL/PhoneClaw/Models/\(modelDir)")

    print("===========================================")
    print("[AudioTest] model=\(modelDir)")
    print("[AudioTest] audio=\(audioPath)")
    print("[AudioTest] prompt=\(prompt)")
    print("===========================================")

    // 1. 解码音频
    guard FileManager.default.fileExists(atPath: audioPath) else {
        print("[AudioTest] ❌ 音频文件不存在: \(audioPath)")
        exit(1)
    }
    let (samples, sampleRate): ([Float], Double)
    do {
        (samples, sampleRate) = try decodeToMonoFloat(url: URL(fileURLWithPath: audioPath))
    } catch {
        print("[AudioTest] ❌ 解码失败: \(error.localizedDescription)")
        exit(1)
    }
    let seconds = Double(samples.count) / sampleRate
    print("[AudioTest] decoded: \(samples.count) samples @ \(Int(sampleRate))Hz = \(String(format: "%.2f", seconds))s")

    // 2. 开启 audio capability 再 register
    Gemma4Registration.setAudioCapabilityEnabled(true)
    await Gemma4Registration.register()
    print("[AudioTest] ✅ gemma4 registered with audio capability")

    // 3. 加载模型
    let loadStart = Date()
    let container: ModelContainer
    do {
        container = try await VLMModelFactory.shared.loadContainer(
            from: modelPath, using: CLITokenizerLoader()
        )
    } catch {
        print("[AudioTest] ❌ 模型加载失败: \(error)")
        exit(1)
    }
    print("[AudioTest] ✅ model loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000))ms")

    // 4. 跑推理
    let mlxAudio: UserInput.Audio = .pcm(.init(
        samples: samples,
        sampleRate: sampleRate,
        channelCount: 1
    ))

    let output: String
    do {
        output = try await container.perform { context in
            // MLXLocalLLMService 的模式: audios 必须通过 chat.user(audios:) 带入,
            // 直接用 UserInput(prompt:, audios:) 在某些 MLXLMCommon 版本里不会
            // 把 audios 接进 input.audios, 导致 Gemma4Processor 看不到音频.
            let input = UserInput(chat: [
                .user(prompt, images: [], audios: [mlxAudio])
            ])
            let prepared = try await context.processor.prepare(input: input)
            print("[AudioTest] input prepared, generating ⬇️")
            print("-------------------------------------------")

            var buffer = ""
            let start = Date()
            var tokenCount = 0
            _ = try MLXLMCommon.generate(
                input: prepared,
                parameters: .init(maxTokens: 512, temperature: 0.7, topP: 0.95, topK: 40),
                context: context
            ) { tokens in
                if let last = tokens.last {
                    let t = context.tokenizer.decode(tokenIds: [last])
                    buffer += t
                    print(t, terminator: "")
                    fflush(stdout)
                    tokenCount = tokens.count
                }
                return tokens.count >= 512 ? .stop : .more
            }
            let elapsed = Date().timeIntervalSince(start)
            print("")
            print("-------------------------------------------")
            print("[AudioTest] \(tokenCount) tokens in \(String(format: "%.2f", elapsed))s = \(String(format: "%.1f", Double(tokenCount) / elapsed)) tok/s")
            return buffer
        }
    } catch {
        print("[AudioTest] ❌ 推理失败: \(error)")
        exit(1)
    }

    print("[AudioTest] output length: \(output.count) chars")
    print("===========================================")
}

await main()
