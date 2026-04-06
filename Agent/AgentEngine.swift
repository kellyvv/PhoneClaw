import CoreImage
import Foundation
import MLXLMCommon
import UIKit

func log(_ message: String) {
    print(message)
}

private extension UserInput.Audio {
    static func from(snapshot: AudioCaptureSnapshot) -> UserInput.Audio {
        .pcm(
            .init(
                samples: snapshot.pcm,
                sampleRate: snapshot.sampleRate,
                channelCount: snapshot.channelCount
            )
        )
    }
}

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    static let selectedModelDefaultsKey = "PhoneClaw.selectedModelID"
    static let enableThinkingDefaultsKey = "PhoneClaw.enableThinking"

    var maxTokens = 4000
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var useGPU = true
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? MLXLocalLLMService.defaultModel.id
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
private let kDefaultSystemPrompt = """
你是 PhoneClaw，一个运行在本地设备上的私人 AI 助手。你完全离线运行，不联网，保护用户隐私。

你拥有以下能力（Skill）：

___SKILLS___

只有当用户明确要求执行某项设备内操作时，才调用 load_skill 加载该能力的详细指令。
像"配置""信息""看看""帮我查一下"这类含糊词，不足以单独触发工具调用。
如果用户只是普通聊天、追问上文、让你解释结果，直接回答，不要调用工具。
如果确实需要某个能力，你必须自己调用 load_skill，不要让用户去"使用某个能力"或"打开某个 skill"。

当且仅当确实需要某个能力时，先调用 load_skill：
<tool_call>
{"name": "load_skill", "arguments": {"skill": "能力名"}}
</tool_call>

在已经拿到工具结果后，优先直接给出最终答案，不要无谓追问。
用中文回答，简洁实用。
"""


// MARK: - 聊天消息

struct ChatImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    private static let storageMaxDimension: CGFloat = 1_024
    private static let compressionQuality: CGFloat = 0.78

    init?(image: UIImage) {
        let prepared = Self.preparedImage(image, maxDimension: Self.storageMaxDimension)
        if let jpeg = prepared.jpegData(compressionQuality: Self.compressionQuality) {
            self.data = jpeg
        } else if let png = prepared.pngData() {
            self.data = png
        } else {
            return nil
        }
    }

    static func preparedImage(_ image: UIImage, maxDimension: CGFloat = storageMaxDimension) -> UIImage {
        let originalSize = image.size
        let longestSide = max(originalSize.width, originalSize.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: max(1, floor(originalSize.width * scale)),
            height: max(1, floor(originalSize.height * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    var uiImage: UIImage? {
        UIImage(data: data)
    }

    var ciImage: CIImage? {
        if let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) {
            return image
        }
        guard let uiImage else { return nil }
        if let ciImage = uiImage.ciImage {
            return ciImage
        }
        if let cgImage = uiImage.cgImage {
            return CIImage(cgImage: cgImage)
        }
        return CIImage(image: uiImage)
    }
}

struct ChatAudioAttachment: Identifiable {
    let id = UUID()
    let wavData: Data
    let duration: TimeInterval
    let sampleRate: Double
    let waveform: [Float]

    init?(snapshot: AudioCaptureSnapshot) {
        guard !snapshot.pcm.isEmpty, snapshot.sampleRate > 0 else { return nil }
        self.wavData = Self.makeWAVData(
            pcm: snapshot.pcm,
            sampleRate: snapshot.sampleRate,
            channelCount: 1
        )
        self.duration = snapshot.duration
        self.sampleRate = snapshot.sampleRate
        self.waveform = Self.makeWaveform(from: snapshot.pcm)
    }

    var formattedDuration: String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func makeWaveform(from pcm: [Float], bucketCount: Int = 36) -> [Float] {
        guard !pcm.isEmpty else { return Array(repeating: 0.12, count: bucketCount) }
        let samplesPerBucket = max(pcm.count / bucketCount, 1)
        var levels: [Float] = []
        levels.reserveCapacity(bucketCount)

        var index = 0
        while index < pcm.count {
            let end = min(index + samplesPerBucket, pcm.count)
            let slice = pcm[index..<end]
            let peak = slice.reduce(Float.zero) { current, sample in
                max(current, abs(sample))
            }
            levels.append(peak)
            index = end
        }

        if levels.count < bucketCount, let last = levels.last {
            levels.append(contentsOf: Array(repeating: last, count: bucketCount - levels.count))
        }
        if levels.count > bucketCount {
            levels = Array(levels.prefix(bucketCount))
        }

        let maxLevel = max(levels.max() ?? 0, 0.001)
        return levels.map { max($0 / maxLevel, 0.08) }
    }

    private static func makeWAVData(
        pcm: [Float],
        sampleRate: Double,
        channelCount: Int
    ) -> Data {
        let integerSampleRate = max(Int(sampleRate.rounded()), 1)
        let clampedSamples = pcm.map { sample -> Int16 in
            let limited = min(max(sample, -1), 1)
            return Int16((limited * Float(Int16.max)).rounded())
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataChunkSize = clampedSamples.count * bytesPerSample
        let riffChunkSize = 36 + dataChunkSize
        let byteRate = integerSampleRate * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataChunkSize)
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(riffChunkSize), to: &data)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(integerSampleRate), to: &data)
        append(UInt32(byteRate), to: &data)
        append(UInt16(blockAlign), to: &data)
        append(UInt16(bytesPerSample * 8), to: &data)
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataChunkSize), to: &data)

        for sample in clampedSamples {
            append(sample, to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    var role: Role
    var content: String
    var images: [ChatImageAttachment]
    var audios: [ChatAudioAttachment]
    let timestamp = Date()
    var skillName: String? = nil

    init(
        role: Role,
        content: String,
        images: [ChatImageAttachment] = [],
        audios: [ChatAudioAttachment] = [],
        skillName: String? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.images = images
        self.audios = audios
        self.skillName = skillName
    }

    mutating func update(content: String) {
        guard self.content != content else { return }
        self.content = content
    }

    mutating func update(role: Role, content: String, skillName: String? = nil) {
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    enum Role {
        case user, assistant, system, skillResult
    }
}

// MARK: - Agent Engine

@Observable
class AgentEngine {

    let llm = MLXLocalLLMService()
    var messages: [ChatMessage] = []
    var isProcessing = false
    var config = ModelConfig()

    // 文件驱动的 Skill 系统
    let skillLoader = SkillLoader()
    let toolRegistry = ToolRegistry.shared

    // Skill 条目（给 UI 管理用，可开关）
    var skillEntries: [SkillEntry] = []

    private let thinkingOpenMarker = "[[PHONECLAW_THINK]]"
    private let thinkingCloseMarker = "[[/PHONECLAW_THINK]]"


    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon, samplePrompt: $0.samplePrompt)
        }
    }

    var availableModels: [BundledModelOption] {
        MLXLocalLLMService.availableModels
    }

    init() {
        loadSkillEntries()
    }

    private func loadSkillEntries() {
        let definitions = skillLoader.discoverSkills()
        self.skillEntries = definitions.map { SkillEntry(from: $0, registry: toolRegistry) }
    }

    func reloadSkills() {
        let enabledState = Dictionary(uniqueKeysWithValues: skillEntries.map { ($0.id, $0.isEnabled) })
        loadSkillEntries()
        for i in skillEntries.indices {
            if let wasEnabled = enabledState[skillEntries[i].id] {
                skillEntries[i].isEnabled = wasEnabled
                skillLoader.setEnabled(skillEntries[i].id, enabled: wasEnabled)
            }
        }
    }

    // MARK: - Skill 查找（文件驱动）

    private func findSkillId(for name: String) -> String? {
        let resolvedName = skillLoader.canonicalSkillId(for: name)
        if skillLoader.getDefinition(resolvedName) != nil { return resolvedName }
        return skillLoader.findSkillId(forTool: name)
    }

    private func findDisplayName(for name: String) -> String {
        if let skillId = findSkillId(for: name),
           let def = skillLoader.getDefinition(skillId) {
            return def.metadata.displayName
        }
        return name
    }

    private func handleLoadSkill(skillName: String) -> String? {
        let resolvedSkillName = skillLoader.canonicalSkillId(for: skillName)
        guard let entry = skillEntries.first(where: { $0.id == resolvedSkillName }),
              entry.isEnabled else {
            return nil
        }
        return skillLoader.loadBody(skillId: resolvedSkillName)
    }

    private func canonicalToolName(_ toolName: String, arguments: [String: Any]) -> String {
        switch toolName {
        case "contacts":
            if arguments["action"] as? String == "delete"
                || arguments["delete"] as? Bool == true {
                return "contacts-delete"
            }
            if arguments["phone"] != nil
                || arguments["company"] != nil
                || arguments["notes"] != nil {
                return "contacts-upsert"
            }
            if arguments["identifier"] != nil
                || arguments["name"] != nil
                || arguments["email"] != nil
                || arguments["query"] != nil {
                return "contacts-search"
            }
            return "contacts-search"
        case "contacts_delete", "contacts-delete-contact":
            return "contacts-delete"
        case "contacts_upsert":
            return "contacts-upsert"
        case "contacts_search":
            return "contacts-search"
        default:
            return toolName
        }
    }

    private func handleToolExecution(toolName: String, args: [String: Any]) async throws -> String {
        return try await toolRegistry.execute(name: toolName, args: args)
    }

    private func autoToolCallForLoadedSkills(
        skillIds: [String]
    ) -> (name: String, arguments: [String: Any])? {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds

        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first,
              let def = skillLoader.getDefinition(skillId),
              def.isEnabled else {
            return nil
        }

        let uniqueToolNames = Array(NSOrderedSet(array: def.metadata.allowedTools)) as? [String]
            ?? def.metadata.allowedTools
        guard uniqueToolNames.count == 1,
              let toolName = uniqueToolNames.first,
              let tool = toolRegistry.find(name: toolName),
              tool.parameters == "无" else {
            return nil
        }

        return (tool.name, [:])
    }

    private func registeredTools(for skillId: String) -> [RegisteredTool] {
        if let def = skillLoader.getDefinition(skillId) {
            let tools = toolRegistry.toolsFor(names: def.metadata.allowedTools)
            if !tools.isEmpty { return tools }
        }

        if let entry = skillEntries.first(where: { $0.id == skillId }) {
            let tools = entry.tools.compactMap { toolRegistry.find(name: $0.name) }
            if !tools.isEmpty { return tools }
        }

        return []
    }

    private func inferFallbackToolCall(
        skillIds: [String],
        userQuestion: String
    ) -> (name: String, arguments: [String: Any])? {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return nil
        }

        let tools = registeredTools(for: skillId)
        guard !tools.isEmpty else { return nil }

        if tools.count == 1, tools[0].parameters == "无" {
            return (tools[0].name, [:])
        }

        let normalizedQuestion = userQuestion.lowercased()

        func has(_ keyword: String) -> Bool {
            normalizedQuestion.contains(keyword)
        }

        let candidateNames: [String]
        switch skillId {
        case "device":
            if has("系统版本") || has("ios 版本") || has("版本号") {
                candidateNames = ["device-system-version", "device-info"]
            } else if has("名字") || has("名称") || has("叫什么") {
                candidateNames = ["device-name", "device-info"]
            } else if has("型号") || has("机型") {
                candidateNames = ["device-model", "device-info"]
            } else if has("内存") || has("ram") {
                candidateNames = ["device-memory", "device-info"]
            } else if has("处理器") || has("核心") || has("cpu") {
                candidateNames = ["device-processor-count", "device-info"]
            } else {
                candidateNames = ["device-info"]
            }
        case "contacts":
            let searchKeywords = [
                "查", "检查", "查询", "看看", "电话", "手机号", "号码",
                "联系方式", "邮箱", "mail", "email"
            ]
            let deleteKeywords = [
                "删除", "删掉", "删了", "删吗", "删", "移除", "去掉", "清除"
            ]
            let upsertKeywords = [
                "存", "保存", "添加", "新建", "创建", "记一下", "记住", "更新", "修改"
            ]

            if deleteKeywords.contains(where: has) {
                candidateNames = ["contacts-delete"]
            } else if upsertKeywords.contains(where: has) {
                candidateNames = ["contacts-upsert"]
            } else if searchKeywords.contains(where: has) {
                candidateNames = ["contacts-search"]
            } else {
                candidateNames = ["contacts-upsert", "contacts-search", "contacts-delete"]
            }
        case "clipboard":
            let writeKeywords = [
                "复制", "拷贝", "写入", "放到剪贴板", "存到剪贴板", "复制到剪贴板"
            ]
            let readKeywords = [
                "剪贴板", "读一下", "读取", "看看", "看下", "查看", "内容"
            ]

            if writeKeywords.contains(where: has),
               let arguments = heuristicArgumentsForTool(toolName: "clipboard-write", userQuestion: userQuestion),
               validateSingleToolArguments(toolName: "clipboard-write", arguments: arguments) {
                return ("clipboard-write", arguments)
            }

            if readKeywords.contains(where: has) {
                candidateNames = ["clipboard-read"]
            } else {
                candidateNames = ["clipboard-read", "clipboard-write"]
            }
        case "calendar":
            let actionKeywords = [
                "安排", "创建", "新建", "加入", "加到", "写进", "写入", "记到"
            ]
            let createIntent =
                (has("日历") || has("日程") || has("会议") || has("约会"))
                && actionKeywords.contains(where: has)
            candidateNames = createIntent ? ["calendar-create-event"] : []
        case "reminders":
            let actionKeywords = [
                "提醒", "提醒我", "记得", "待办", "创建", "新建", "添加"
            ]
            let createIntent = actionKeywords.contains(where: has)
            candidateNames = createIntent ? ["reminders-create"] : []
        case "text":
            if has("哈希") || has("hash") {
                candidateNames = ["calculate-hash"]
            } else if has("翻转") || has("反转") {
                candidateNames = ["text-reverse"]
            } else {
                candidateNames = ["calculate-hash", "text-reverse"]
            }
        default:
            candidateNames = []
        }

        for name in candidateNames {
            guard let tool = tools.first(where: { $0.name == name }) else { continue }
            if tool.parameters == "无" {
                return (tool.name, [:])
            }
            if let arguments = heuristicArgumentsForTool(toolName: tool.name, userQuestion: userQuestion),
               validateSingleToolArguments(toolName: tool.name, arguments: arguments) {
                return (tool.name, arguments)
            }
        }

        return nil
    }

    private enum SingleToolExtractionOutcome {
        case toolCall(name: String, arguments: [String: Any])
        case needsClarification(String)
        case failed
    }

    private func singleRegisteredToolForLoadedSkills(skillIds: [String]) -> RegisteredTool? {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return nil
        }

        let tools = registeredTools(for: skillId)
        guard tools.count == 1 else { return nil }
        return tools.first
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidates: [String] = {
            if trimmed.hasPrefix("```json") || trimmed.hasPrefix("```") {
                let stripped = trimmed
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return [stripped]
            }

            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start <= end {
                return [trimmed, String(trimmed[start...end])]
            }

            return [trimmed]
        }()

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }

        return nil
    }

    private func iso8601StringForModel(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func chineseNumberValue(_ token: String) -> Int? {
        if let value = Int(token) { return value }

        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]

        if token == "十" { return 10 }
        if token.hasPrefix("十"), let last = token.last, let digit = digits[last] {
            return 10 + digit
        }
        if token.hasSuffix("十"), let first = token.first, let digit = digits[first] {
            return digit * 10
        }
        if token.count == 2 {
            let chars = Array(token)
            if let tens = digits[chars[0]], chars[1] == "十" {
                return tens * 10
            }
        }
        if token.count == 3 {
            let chars = Array(token)
            if let tens = digits[chars[0]], chars[1] == "十", let ones = digits[chars[2]] {
                return tens * 10 + ones
            }
        }

        return nil
    }

    private func parseBasicChineseDate(from text: String) -> Date? {
        let patterns = [
            "(今天|今日|今晚|今夜|明天|明晚|后天)(?:的)?(凌晨|早上|上午|中午|下午|晚上|傍晚)?([零〇一二两三四五六七八九十\\d]{1,3})点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?",
            "(凌晨|早上|上午|中午|下午|晚上|傍晚)([零〇一二两三四五六七八九十\\d]{1,3})点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }

            var dayToken: String?
            var periodToken: String?
            var hourToken: String?
            var hasHalf = false
            var minuteToken: String?

            if match.numberOfRanges >= 6 {
                if let r = Range(match.range(at: 1), in: text), !r.isEmpty {
                    dayToken = String(text[r])
                }
                if let r = Range(match.range(at: 2), in: text), !r.isEmpty {
                    periodToken = String(text[r])
                }
                if let r = Range(match.range(at: 3), in: text), !r.isEmpty {
                    hourToken = String(text[r])
                }
                if let r = Range(match.range(at: 4), in: text), !r.isEmpty {
                    hasHalf = true
                }
                if let r = Range(match.range(at: 5), in: text), !r.isEmpty {
                    minuteToken = String(text[r])
                }
            }

            if hourToken == nil, match.numberOfRanges >= 5 {
                if let r = Range(match.range(at: 1), in: text), !r.isEmpty {
                    periodToken = String(text[r])
                }
                if let r = Range(match.range(at: 2), in: text), !r.isEmpty {
                    hourToken = String(text[r])
                }
                if let r = Range(match.range(at: 3), in: text), !r.isEmpty {
                    hasHalf = true
                }
                if let r = Range(match.range(at: 4), in: text), !r.isEmpty {
                    minuteToken = String(text[r])
                }
            }

            guard let hourToken,
                  var hour = chineseNumberValue(hourToken) else {
                continue
            }

            var minute = 0
            if hasHalf {
                minute = 30
            } else if let minuteToken, let parsedMinute = chineseNumberValue(minuteToken) {
                minute = parsedMinute
            }

            if let periodToken {
                switch periodToken {
                case "下午", "晚上", "傍晚":
                    if hour < 12 { hour += 12 }
                case "中午":
                    if hour < 11 { hour += 12 }
                case "凌晨":
                    if hour == 12 { hour = 0 }
                default:
                    break
                }
            }

            var dayOffset = 0
            switch dayToken {
            case "明天", "明晚":
                dayOffset = 1
            case "后天":
                dayOffset = 2
            default:
                dayOffset = 0
            }

            let calendar = Calendar.current
            let baseDate = calendar.startOfDay(for: Date())
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: baseDate),
                  let finalDate = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: day
                  ) else {
                continue
            }
            return finalDate
        }

        return nil
    }

    private func detectDateInQuestion(_ text: String) -> Date? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, options: [], range: range),
               let date = match.date {
                return date
            }
        }
        return parseBasicChineseDate(from: text)
    }

    private func heuristicArgumentsForTool(
        toolName: String,
        userQuestion: String
    ) -> [String: Any]? {
        let text = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        switch toolName {
        case "calculate-hash":
            let patterns = [
                "(?:计算|求|生成|算一下|帮我算)(.+?)(?:的)?(?:哈希|hash)(?:值)?",
                "(.+?)(?:的)?(?:哈希|hash)(?:值)?(?:是多少|是什么)?"
            ]

            var extracted: String?
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                    if !value.isEmpty {
                        extracted = value
                        break
                    }
                }
            }

            if extracted == nil {
                let cleaned = text
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "计算", with: "")
                    .replacingOccurrences(of: "求", with: "")
                    .replacingOccurrences(of: "生成", with: "")
                    .replacingOccurrences(of: "算一下", with: "")
                    .replacingOccurrences(of: "哈希值", with: "")
                    .replacingOccurrences(of: "哈希", with: "")
                    .replacingOccurrences(of: "hash", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                if !cleaned.isEmpty {
                    extracted = cleaned
                }
            }

            guard let extracted, !extracted.isEmpty else { return nil }
            return ["text": extracted]

        case "text-reverse":
            let patterns = [
                "(?:把|将)(.+?)(?:翻转|反转)(?:过来|一下)?",
                "(?:翻转|反转)(.+?)(?:过来|一下)?$"
            ]

            var extracted: String?
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                    if !value.isEmpty {
                        extracted = value
                        break
                    }
                }
            }

            if extracted == nil {
                let cleaned = text
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "把", with: "")
                    .replacingOccurrences(of: "将", with: "")
                    .replacingOccurrences(of: "翻转过来", with: "")
                    .replacingOccurrences(of: "反转过来", with: "")
                    .replacingOccurrences(of: "翻转一下", with: "")
                    .replacingOccurrences(of: "反转一下", with: "")
                    .replacingOccurrences(of: "翻转", with: "")
                    .replacingOccurrences(of: "反转", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                if !cleaned.isEmpty {
                    extracted = cleaned
                }
            }

            guard let extracted, !extracted.isEmpty else { return nil }
            return ["text": extracted]

        case "clipboard-write":
            let patterns = [
                "(?:复制|拷贝|写入)(.+?)(?:到|进|到系统)?(?:剪贴板)",
                "(?:把|将)(.+?)(?:复制|拷贝|写入)(?:到|进)?(?:剪贴板)"
            ]

            var extracted: String?
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                    if !value.isEmpty {
                        extracted = value
                        break
                    }
                }
            }

            if extracted == nil {
                let cleaned = text
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "把", with: "")
                    .replacingOccurrences(of: "将", with: "")
                    .replacingOccurrences(of: "复制到剪贴板", with: "")
                    .replacingOccurrences(of: "拷贝到剪贴板", with: "")
                    .replacingOccurrences(of: "写入剪贴板", with: "")
                    .replacingOccurrences(of: "放到剪贴板", with: "")
                    .replacingOccurrences(of: "存到剪贴板", with: "")
                    .replacingOccurrences(of: "复制", with: "")
                    .replacingOccurrences(of: "拷贝", with: "")
                    .replacingOccurrences(of: "写入", with: "")
                    .replacingOccurrences(of: "剪贴板", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
                if !cleaned.isEmpty {
                    extracted = cleaned
                }
            }

            guard let extracted, !extracted.isEmpty else { return nil }
            return ["text": extracted]

        case "contacts-upsert":
            let phone = text.firstMatch(of: /1[3-9]\d{9}/).map { String($0.0) }
            var name: String?

            let patterns = [
                "(?:把|将)?(.+?)(?:的)?(?:电话|手机号|号码|联系方式)\\s*(?:1[3-9]\\d{9})\\s*(?:添加到|加到|存到|保存到)?(?:联系人|通讯录)",
                "(?:帮我)?(?:存(?:一下)?|保存|记一下)(.+?)(?:的)?(?:电话|手机号|号码|联系方式)",
                "(?:联系人|通讯录)(?:里)?(?:添加|保存)?(.+?)(?:的)?(?:电话|手机号|号码|联系方式)"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    name = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            if name == nil,
               let phone,
               let phoneRange = text.range(of: phone) {
                let prefix = text[..<phoneRange.lowerBound]
                let cleaned = prefix
                    .replacingOccurrences(of: "把", with: "")
                    .replacingOccurrences(of: "将", with: "")
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "存一下", with: "")
                    .replacingOccurrences(of: "保存", with: "")
                    .replacingOccurrences(of: "添加到联系人", with: "")
                    .replacingOccurrences(of: "添加到通讯录", with: "")
                    .replacingOccurrences(of: "加到联系人", with: "")
                    .replacingOccurrences(of: "加到通讯录", with: "")
                    .replacingOccurrences(of: "存到联系人", with: "")
                    .replacingOccurrences(of: "存到通讯录", with: "")
                    .replacingOccurrences(of: "联系人", with: "")
                    .replacingOccurrences(of: "通讯录", with: "")
                    .replacingOccurrences(of: "的电话", with: "")
                    .replacingOccurrences(of: "电话", with: "")
                    .replacingOccurrences(of: "手机号", with: "")
                    .replacingOccurrences(of: "号码", with: "")
                    .replacingOccurrences(of: "联系方式", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    name = cleaned
                }
            }

            var company: String?
            if let regex = try? NSRegularExpression(pattern: "[，,]\\s*([^，。,]+?)(?:的)?\\s*$") {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, value != phone {
                        company = value
                    }
                }
            }

            guard let name, !name.isEmpty else { return nil }
            var result: [String: Any] = ["name": name]
            if let phone { result["phone"] = phone }
            if let company, !company.isEmpty { result["company"] = company }
            return result

        case "contacts-search":
            let phone = text.firstMatch(of: /1[3-9]\d{9}/).map { String($0.0) }
            let email: String? = {
                guard let regex = try? NSRegularExpression(
                    pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
                    options: [.caseInsensitive]
                ) else {
                    return nil
                }
                let range = NSRange(text.startIndex..., in: text)
                guard let match = regex.firstMatch(in: text, range: range),
                      let capture = Range(match.range, in: text) else {
                    return nil
                }
                return String(text[capture])
            }()

            var name: String?
            let patterns = [
                "(?:检查下?|查(?:一下|下)?|查询|看看)(?:联系人|通讯录)?(.+?)(?:的)?(?:电话|手机号|号码|联系方式|邮箱)",
                "(?:联系人|通讯录)?(.+?)(?:的)?(?:电话|手机号|号码|联系方式|邮箱)(?:是)?(?:多少|是什么|有吗)?"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        name = value
                        break
                    }
                }
            }

            if name == nil {
                let cleaned = text
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "检查下", with: "")
                    .replacingOccurrences(of: "检查", with: "")
                    .replacingOccurrences(of: "查一下", with: "")
                    .replacingOccurrences(of: "查下", with: "")
                    .replacingOccurrences(of: "查询", with: "")
                    .replacingOccurrences(of: "看看", with: "")
                    .replacingOccurrences(of: "联系人", with: "")
                    .replacingOccurrences(of: "通讯录", with: "")
                    .replacingOccurrences(of: "的电话多少", with: "")
                    .replacingOccurrences(of: "的电话", with: "")
                    .replacingOccurrences(of: "电话多少", with: "")
                    .replacingOccurrences(of: "电话", with: "")
                    .replacingOccurrences(of: "手机号", with: "")
                    .replacingOccurrences(of: "号码", with: "")
                    .replacingOccurrences(of: "联系方式", with: "")
                    .replacingOccurrences(of: "邮箱", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    name = cleaned
                }
            }

            var result: [String: Any] = [:]
            if let name, !name.isEmpty { result["name"] = name }
            if let phone { result["phone"] = phone }
            if let email { result["email"] = email }
            if result.isEmpty {
                result["query"] = text
            }
            return result

        case "contacts-delete":
            let phone = text.firstMatch(of: /1[3-9]\d{9}/).map { String($0.0) }
            let email: String? = {
                guard let regex = try? NSRegularExpression(
                    pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
                    options: [.caseInsensitive]
                ) else {
                    return nil
                }
                let range = NSRange(text.startIndex..., in: text)
                guard let match = regex.firstMatch(in: text, range: range),
                      let capture = Range(match.range, in: text) else {
                    return nil
                }
                return String(text[capture])
            }()

            var name: String?
            let patterns = [
                "(?:把|将)(.+?)(?:的)?(?:电话|手机号|号码|联系方式)?(?:从)?(?:联系人|通讯录)?(?:里|中)?(?:删除|删掉|删了|删吗|删|移除|去掉)",
                "(?:删除|删掉|删了|删吗|删|移除|去掉)(?:联系人|通讯录)?(?:里|中)?(.+)"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range),
                   let capture = Range(match.range(at: 1), in: text) {
                    let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        name = value
                        break
                    }
                }
            }

            if name == nil {
                let cleaned = text
                    .replacingOccurrences(of: "帮我", with: "")
                    .replacingOccurrences(of: "把", with: "")
                    .replacingOccurrences(of: "将", with: "")
                    .replacingOccurrences(of: "从联系人中", with: "")
                    .replacingOccurrences(of: "从联系人里", with: "")
                    .replacingOccurrences(of: "从通讯录中", with: "")
                    .replacingOccurrences(of: "从通讯录里", with: "")
                    .replacingOccurrences(of: "联系人中", with: "")
                    .replacingOccurrences(of: "联系人里", with: "")
                    .replacingOccurrences(of: "通讯录中", with: "")
                    .replacingOccurrences(of: "通讯录里", with: "")
                    .replacingOccurrences(of: "联系人", with: "")
                    .replacingOccurrences(of: "通讯录", with: "")
                    .replacingOccurrences(of: "的电话", with: "")
                    .replacingOccurrences(of: "电话", with: "")
                    .replacingOccurrences(of: "手机号", with: "")
                    .replacingOccurrences(of: "号码", with: "")
                    .replacingOccurrences(of: "联系方式", with: "")
                    .replacingOccurrences(of: "删除", with: "")
                    .replacingOccurrences(of: "删掉", with: "")
                    .replacingOccurrences(of: "删了吗", with: "")
                    .replacingOccurrences(of: "删了", with: "")
                    .replacingOccurrences(of: "删吗", with: "")
                    .replacingOccurrences(of: "删", with: "")
                    .replacingOccurrences(of: "移除", with: "")
                    .replacingOccurrences(of: "去掉", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    name = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "，。,？！!? "))
                }
            }

            var result: [String: Any] = [:]
            if let name, !name.isEmpty { result["name"] = name }
            if let phone { result["phone"] = phone }
            if let email { result["email"] = email }
            if result.isEmpty {
                result["query"] = text
            }
            return result

        case "reminders-create":
            let due = detectDateInQuestion(text).map { iso8601StringForModel(from: $0) }
            var title = text
                .replacingOccurrences(of: "帮我", with: "")
                .replacingOccurrences(of: "提醒我", with: "")
                .replacingOccurrences(of: "提醒", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let cleanupPatterns = [
                "(今天|今日|今晚|今夜|明天|明晚|后天)(?:的)?(凌晨|早上|上午|中午|下午|晚上|傍晚)?[零〇一二两三四五六七八九十\\d]{1,3}点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?",
                "(凌晨|早上|上午|中午|下午|晚上|傍晚)[零〇一二两三四五六七八九十\\d]{1,3}点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?"
            ]
            for pattern in cleanupPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    title = regex.stringByReplacingMatches(
                        in: title,
                        range: NSRange(title.startIndex..., in: title),
                        withTemplate: ""
                    )
                }
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty else { return nil }
            var result: [String: Any] = ["title": title]
            if let due { result["due"] = due }
            return result

        case "calendar-create-event":
            let start = detectDateInQuestion(text).map { iso8601StringForModel(from: $0) }
            var title = text
                .replacingOccurrences(of: "帮我", with: "")
                .replacingOccurrences(of: "安排", with: "")
                .replacingOccurrences(of: "创建一个", with: "")
                .replacingOccurrences(of: "创建", with: "")
                .replacingOccurrences(of: "日历", with: "")
                .replacingOccurrences(of: "事项", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanupPatterns = [
                "(今天|今日|今晚|今夜|明天|明晚|后天)(?:的)?(凌晨|早上|上午|中午|下午|晚上|傍晚)?[零〇一二两三四五六七八九十\\d]{1,3}点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?",
                "(凌晨|早上|上午|中午|下午|晚上|傍晚)[零〇一二两三四五六七八九十\\d]{1,3}点(?:(半)|([零〇一二两三四五六七八九十\\d]{1,3})分?)?"
            ]
            for pattern in cleanupPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    title = regex.stringByReplacingMatches(
                        in: title,
                        range: NSRange(title.startIndex..., in: title),
                        withTemplate: ""
                    )
                }
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty, let start else { return nil }
            return ["title": title, "start": start]

        default:
            return nil
        }
    }

    private func validateSingleToolArguments(
        toolName: String,
        arguments: [String: Any]
    ) -> Bool {
        switch toolName {
        case "calendar-create-event":
            return arguments["title"] is String && arguments["start"] is String
        case "reminders-create":
            return arguments["title"] is String
        case "calculate-hash", "text-reverse":
            return arguments["text"] is String
        case "contacts-upsert":
            return arguments["name"] is String
        case "contacts-search", "contacts-delete":
            return arguments["query"] is String
                || arguments["identifier"] is String
                || arguments["name"] is String
                || arguments["phone"] is String
                || arguments["email"] is String
        case "clipboard-write":
            return arguments["text"] is String
        default:
            return !arguments.isEmpty
        }
    }

    private func shouldSkipToolFollowUpModel(for toolName: String) -> Bool {
        switch toolName {
        case "clipboard-read", "clipboard-write":
            return true
        default:
            return false
        }
    }

    private func preflightSkillLoadCall(for userQuestion: String) -> String? {
        let normalizedQuestion = userQuestion.lowercased()

        func has(_ keyword: String) -> Bool {
            normalizedQuestion.contains(keyword)
        }

        if (has("哈希") || has("hash")),
           let arguments = heuristicArgumentsForTool(toolName: "calculate-hash", userQuestion: userQuestion),
           validateSingleToolArguments(toolName: "calculate-hash", arguments: arguments) {
            return syntheticToolCallText(
                name: "calculate-hash",
                arguments: arguments
            )
        }

        if (has("翻转") || has("反转")),
           let arguments = heuristicArgumentsForTool(toolName: "text-reverse", userQuestion: userQuestion),
           validateSingleToolArguments(toolName: "text-reverse", arguments: arguments) {
            return syntheticToolCallText(
                name: "text-reverse",
                arguments: arguments
            )
        }

        let mentionsClipboard = has("剪贴板") || has("clipboard")
        if mentionsClipboard {
            let readKeywords = ["读取", "读一下", "看看", "看下", "查看", "内容", "是什么"]
            let writeKeywords = ["复制", "拷贝", "写入", "放到剪贴板", "存到剪贴板", "复制到剪贴板"]

            if writeKeywords.contains(where: has),
               let arguments = heuristicArgumentsForTool(toolName: "clipboard-write", userQuestion: userQuestion),
               validateSingleToolArguments(toolName: "clipboard-write", arguments: arguments) {
                return syntheticToolCallText(
                    name: "clipboard-write",
                    arguments: arguments
                )
            }

            if readKeywords.contains(where: has) || mentionsClipboard {
                return syntheticToolCallText(
                    name: "load_skill",
                    arguments: ["skill": "clipboard"]
                )
            }
        }

        let calendarIntent =
            (has("日历") || has("日程") || has("会议") || has("约会"))
            && ["安排", "创建", "新建", "加入", "加到", "记到", "写进", "写入"].contains(where: has)
        if calendarIntent {
            if let arguments = heuristicArgumentsForTool(toolName: "calendar-create-event", userQuestion: userQuestion),
               validateSingleToolArguments(toolName: "calendar-create-event", arguments: arguments) {
                return syntheticToolCallText(
                    name: "calendar-create-event",
                    arguments: arguments
                )
            }
            return syntheticToolCallText(
                name: "load_skill",
                arguments: ["skill": "calendar"]
            )
        }

        let reminderIntent = ["提醒我", "提醒", "记得", "待办", "提醒事项"].contains(where: has)
        if reminderIntent {
            if let arguments = heuristicArgumentsForTool(toolName: "reminders-create", userQuestion: userQuestion),
               validateSingleToolArguments(toolName: "reminders-create", arguments: arguments) {
                return syntheticToolCallText(
                    name: "reminders-create",
                    arguments: arguments
                )
            }
            return syntheticToolCallText(
                name: "load_skill",
                arguments: ["skill": "reminders"]
            )
        }

        return nil
    }

    private func extractToolCallForLoadedSkills(
        originalPrompt: String,
        userQuestion: String,
        skillInstructions: String,
        skillIds: [String],
        images: [CIImage]
    ) async -> SingleToolExtractionOutcome {
        let uniqueSkillIds = Array(NSOrderedSet(array: skillIds)) as? [String] ?? skillIds
        guard uniqueSkillIds.count == 1,
              let skillId = uniqueSkillIds.first else {
            return .failed
        }

        let tools = registeredTools(for: skillId)
            .filter { $0.parameters != "无" }
        guard !tools.isEmpty else {
            return .failed
        }

        if tools.count == 1, let tool = tools.first {
            if let heuristic = heuristicArgumentsForTool(toolName: tool.name, userQuestion: userQuestion),
               validateSingleToolArguments(toolName: tool.name, arguments: heuristic) {
                log("[Agent] load_skill heuristic 直接执行工具: \(tool.name)")
                return .toolCall(name: tool.name, arguments: heuristic)
            }

            let extractionPrompt = PromptBuilder.buildSingleToolArgumentsPrompt(
                originalPrompt: originalPrompt,
                userQuestion: userQuestion,
                skillInstructions: skillInstructions,
                toolName: tool.name,
                toolParameters: tool.parameters,
                currentImageCount: images.count
            )

            if let raw = await streamLLM(prompt: extractionPrompt, images: images) {
                let cleaned = cleanOutput(raw)
                if let payload = parseJSONObject(cleaned) {
                    if let clarification = payload["_needs_clarification"] as? String,
                       !clarification.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        return .needsClarification(clarification)
                    }

                    if validateSingleToolArguments(toolName: tool.name, arguments: payload) {
                        return .toolCall(name: tool.name, arguments: payload)
                    }
                }
            }

            return .failed
        }

        let allowedToolsSummary = tools.map {
            "- \($0.name): \($0.description)\n  参数: \($0.parameters)"
        }.joined(separator: "\n")

        let extractionPrompt = PromptBuilder.buildSkillToolSelectionPrompt(
            originalPrompt: originalPrompt,
            userQuestion: userQuestion,
            skillInstructions: skillInstructions,
            allowedToolsSummary: allowedToolsSummary,
            currentImageCount: images.count
        )

        if let raw = await streamLLM(prompt: extractionPrompt, images: images) {
            let cleaned = cleanOutput(raw)
            if let payload = parseJSONObject(cleaned) {
                if let clarification = payload["_needs_clarification"] as? String,
                   !clarification.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    return .needsClarification(clarification)
                }

                if let rawName = payload["name"] as? String,
                   let arguments = payload["arguments"] as? [String: Any] {
                    let toolName = canonicalToolName(rawName, arguments: arguments)
                    if tools.contains(where: { $0.name == toolName }),
                       validateSingleToolArguments(toolName: toolName, arguments: arguments) {
                        return .toolCall(name: toolName, arguments: arguments)
                    }
                }
            }
        }

        if let heuristic = inferFallbackToolCall(skillIds: skillIds, userQuestion: userQuestion),
           tools.contains(where: { $0.name == heuristic.name }),
           validateSingleToolArguments(toolName: heuristic.name, arguments: heuristic.arguments) {
            return .toolCall(name: heuristic.name, arguments: heuristic.arguments)
        }

        return .failed
    }

    private func markSkillsDone(_ displayNames: [String]) {
        guard !displayNames.isEmpty else { return }
        for index in messages.indices {
            guard messages[index].role == .system,
                  let skillName = messages[index].skillName,
                  displayNames.contains(skillName),
                  messages[index].content == "identified" || messages[index].content == "loaded" else {
                continue
            }
            messages[index].update(role: .system, content: "done", skillName: skillName)
        }
    }

    private func looksLikeStructuredIntermediateOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("```json") || trimmed.hasPrefix("```") {
            return true
        }

        if let regex = try? NSRegularExpression(
            pattern: "\"[A-Za-z_][A-Za-z0-9_]*\"\\s*:",
            options: []
        ) {
            let matchCount = regex.numberOfMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            )
            if matchCount >= 2 && !trimmed.hasPrefix("{") {
                return true
            }
        }

        let suspiciousFragments = [
            "tool_name\":",
            "result_for_user_name\":",
            "text_for_display\":",
            "tool_operation_success\":",
            "arguments_for_tool_no_skill\":",
            "memory_user_power_conversion\":"
        ]
        if suspiciousFragments.filter({ trimmed.contains($0) }).count >= 2 {
            return true
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if let dict = json as? [String: Any] {
            if dict["name"] != nil {
                return false
            }

            let suspiciousKeys = [
                "final_answer", "tool_call", "arguments", "device_call",
                "next_action", "action", "tool"
            ]
            return suspiciousKeys.contains { dict[$0] != nil }
        }

        return false
    }

    private func looksLikePromptEcho(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("user\n") || trimmed == "user" {
            return true
        }

        let suspiciousPhrases = [
            "根据已加载的 Skill",
            "不要将任何关于工具、系统或该请求的描述变成 Markdown 代码或 JSON 模板",
            "如果需要，请直接调用",
            "package_name",
            "text_for_user"
        ]

        let hitCount = suspiciousPhrases.reduce(into: 0) { count, phrase in
            if trimmed.contains(phrase) { count += 1 }
        }
        return hitCount >= 2
    }

    private func syntheticToolCallText(
        name: String,
        arguments: [String: Any]
    ) -> String {
        let jsonData = try? JSONSerialization.data(withJSONObject: [
            "name": name,
            "arguments": arguments
        ])
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"name\":\"\(name)\",\"arguments\":{}}"
        return """
        <tool_call>
        \(jsonString)
        </tool_call>
        """
    }

    private func parsedToolPayload(from toolResult: String) -> [String: Any]? {
        guard let data = toolResult.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func toolResultSummaryForModel(
        toolName: String,
        toolResult: String
    ) -> String {
        let trimmed = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "工具 \(toolName) 已执行，但没有返回内容。" }

        if let payload = parsedToolPayload(from: trimmed) {
            if let success = payload["success"] as? Bool,
               !success,
               let error = payload["error"] as? String,
               !error.isEmpty {
                return "工具 \(toolName) 执行失败：\(error)"
            }

            if let result = payload["result"] as? String {
                let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !summary.isEmpty { return summary }
            }
        }

        if let rendered = renderToolResultLocally(toolName: toolName, toolResult: trimmed) {
            return rendered
        }

        return trimmed
    }

    private func fallbackReplyForEmptyToolFollowUp(toolName: String, toolResult: String) -> String {
        let trimmed = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = toolResultSummaryForModel(toolName: toolName, toolResult: trimmed)
        if !summary.isEmpty, summary != trimmed {
            return summary
        }

        if trimmed.isEmpty {
            return "工具 \(toolName) 已执行，但没有返回内容。"
        }

        return """
        工具 \(toolName) 已执行完成，但模型没有生成最终回答。
        工具返回结果：
        \(trimmed)
        """
    }

    private func renderToolResultLocally(
        toolName: String,
        toolResult: String
    ) -> String? {
        guard let payload = parsedToolPayload(from: toolResult),
              let success = payload["success"] as? Bool,
              success else {
            return nil
        }

        func string(_ key: String) -> String? {
            if let value = payload[key] as? String, !value.isEmpty { return value }
            return nil
        }

        func int(_ key: String) -> Int? {
            if let value = payload[key] as? Int { return value }
            if let value = payload[key] as? Double { return Int(value) }
            if let value = payload[key] as? String, let intValue = Int(value) { return intValue }
            return nil
        }

        func double(_ key: String) -> Double? {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? String, let doubleValue = Double(value) { return doubleValue }
            return nil
        }

        switch toolName {
        case "device-info":
            var lines: [String] = []
            if let name = string("name") {
                lines.append("设备名称：\(name)")
            }
            if let localizedModel = string("localized_model") ?? string("model") {
                lines.append("设备类型：\(localizedModel)")
            }
            if let systemName = string("system_name"),
               let systemVersion = string("system_version") {
                lines.append("系统版本：\(systemName) \(systemVersion)")
            } else if let systemVersion = string("system_version") {
                lines.append("系统版本：\(systemVersion)")
            }
            if let memoryGB = double("memory_gb") {
                lines.append(String(format: "物理内存：%.1f GB", memoryGB))
            }
            if let processorCount = int("processor_count") {
                lines.append("处理器核心数：\(processorCount)")
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")

        case "device-name":
            if let name = string("name") {
                return "这台设备的名称是 \(name)。"
            }

        case "device-model":
            if let localizedModel = string("localized_model") ?? string("model") {
                return "这台设备的官方设备类型是 \(localizedModel)。"
            }

        case "device-system-version":
            if let systemName = string("system_name"),
               let systemVersion = string("system_version") {
                return "当前系统版本是 \(systemName) \(systemVersion)。"
            }

        case "device-memory":
            if let memoryGB = double("memory_gb") {
                return String(format: "这台设备的物理内存约为 %.1f GB。", memoryGB)
            }

        case "device-processor-count":
            if let processorCount = int("processor_count") {
                return "这台设备的处理器核心数是 \(processorCount)。"
            }

        case "device-identifier-for-vendor":
            if let identifier = string("identifier_for_vendor") {
                return "当前 App 在这台设备上的 identifierForVendor 是 \(identifier)。"
            }

        case "clipboard-read":
            if let content = string("content") {
                return "剪贴板当前内容是：\(content)"
            }

        case "clipboard-write":
            if let copiedLength = int("copied_length") {
                return "已写入剪贴板，共 \(copiedLength) 个字符。"
            }

        case "text-reverse":
            if let reversed = string("reversed") {
                return "翻转结果：\(reversed)"
            }

        case "calculate-hash":
            if let hash = payload["hash"] {
                return "哈希值是 \(hash)。"
            }

        case "calendar-create-event":
            if let title = string("title"),
               let start = string("start") {
                var parts = ["已创建日历事项“\(title)”", "开始时间是 \(start)"]
                if let location = string("location") {
                    parts.append("地点是 \(location)")
                }
                return parts.joined(separator: "，") + "。"
            }

        case "reminders-create":
            if let title = string("title") {
                if let due = string("due") {
                    return "已创建提醒事项“\(title)”，提醒时间是 \(due)。"
                }
                return "已创建提醒事项“\(title)”。"
            }

        case "contacts-upsert":
            if let name = string("name") {
                let action = string("action") == "updated" ? "已更新" : "已创建"
                var parts = ["\(action)联系人“\(name)”"]
                if let phone = string("phone") {
                    parts.append("手机号是 \(phone)")
                }
                if let company = string("company") {
                    parts.append("公司是 \(company)")
                }
                return parts.joined(separator: "，") + "。"
            }

        case "contacts-search":
            if let result = string("result") {
                return result
            }

        case "contacts-delete":
            if let result = string("result") {
                return result
            }

        default:
            break
        }

        return nil
    }

    private func fallbackReplyForEmptySkillFollowUp(skillName: String) -> String {
        "Skill \(skillName) 已加载，但模型没有继续生成工具调用或最终回答。请重试，或把问题说得更具体一些。"
    }

    private func shouldUseToolingPrompt(for userQuestion: String) -> Bool {
        let normalizedQuestion = userQuestion.lowercased()
        guard !normalizedQuestion.isEmpty else { return false }

        let domainKeywords = [
            "日历", "提醒", "提醒事项", "通讯录", "联系人", "剪贴板",
            "设备", "系统", "相册", "照片", "蓝牙", "wifi", "电量",
            "亮度", "音量", "电话", "短信", "邮件"
        ]
        let actionKeywords = [
            "打开", "查看", "读取", "搜索", "查询", "创建",
            "新建", "添加", "保存", "修改", "删除", "复制",
            "拨打", "发送", "设置", "调高", "调低"
        ]

        let mentionsDomain = domainKeywords.contains { normalizedQuestion.contains($0) }
        let mentionsAction = actionKeywords.contains { normalizedQuestion.contains($0) }
        if mentionsDomain && mentionsAction {
            return true
        }

        for entry in skillEntries where entry.isEnabled {
            if normalizedQuestion.contains(entry.id.lowercased())
                || normalizedQuestion.contains(entry.name.lowercased())
            {
                return true
            }

            if entry.tools.contains(where: { normalizedQuestion.contains($0.name.lowercased()) }) {
                return true
            }

            if let definition = skillLoader.getDefinition(entry.id),
               definition.metadata.triggers.contains(where: { trigger in
                   let normalizedTrigger = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                   return !normalizedTrigger.isEmpty && normalizedQuestion.contains(normalizedTrigger)
               })
            {
                return true
            }
        }

        return mentionsDomain
    }

    // MARK: - 初始化

    /// ConfigurationsView 的"Restore default"按钮使用。
    var defaultSystemPrompt: String { kDefaultSystemPrompt }

    func setup() {
        applyModelSelection()
        llm.refreshModelInstallStates()
        loadSystemPrompt()       // 从 SYSPROMPT.md 注入 system prompt
        applySamplingConfig()
        llm.loadModel()
    }

    // MARK: - SYSPROMPT 注入

    /// 从 ApplicationSupport/PhoneClaw/SYSPROMPT.md 读取 system prompt。
    /// 文件不存在时自动写入 kDefaultSystemPrompt（供用户后续编辑）。
    func loadSystemPrompt() {
        let fm = FileManager.default
        guard let supportDir = fm.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first else { return }
        let dir  = supportDir.appendingPathComponent("PhoneClaw", isDirectory: true)
        let file = dir.appendingPathComponent("SYSPROMPT.md")

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: file.path),
           let content = try? String(contentsOf: file, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.systemPrompt = content
            print("[Agent] SYSPROMPT loaded (\(content.count) chars)")
        } else {
            try? kDefaultSystemPrompt.write(to: file, atomically: true, encoding: .utf8)
            config.systemPrompt = kDefaultSystemPrompt
            print("[Agent] SYSPROMPT not found — default written to \(file.path)")
        }
    }

    func applySamplingConfig() {
        llm.samplingTopK = config.topK
        llm.samplingTopP = Float(config.topP)
        llm.samplingTemperature = Float(config.temperature)
        llm.maxOutputTokens = config.maxTokens
        UserDefaults.standard.set(
            config.enableThinking,
            forKey: ModelConfig.enableThinkingDefaultsKey
        )
    }

    @discardableResult
    func applyModelSelection() -> Bool {
        UserDefaults.standard.set(
            config.selectedModelID,
            forKey: ModelConfig.selectedModelDefaultsKey
        )
        return llm.selectModel(id: config.selectedModelID)
    }

    func reloadModel() {
        let selectedModelID = config.selectedModelID
        Task { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            _ = self.llm.selectModel(id: selectedModelID)
            await self.llm.prepareForReload()
            self.llm.loadModel()
        }
    }

    func permissionStatuses() -> [AppPermissionKind: AppPermissionStatus] {
        toolRegistry.allPermissionStatuses()
    }

    func requestPermission(_ kind: AppPermissionKind) async -> AppPermissionStatus {
        do {
            _ = try await toolRegistry.requestAccess(for: kind)
        } catch {
            log("[Permission] \(kind.rawValue) request failed: \(error.localizedDescription)")
        }
        return toolRegistry.authorizationStatus(for: kind)
    }

    // MARK: - 处理用户输入（MLX 流式输出）

    func processInput(
        _ text: String,
        images: [UIImage] = [],
        audio: AudioCaptureSnapshot? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmed
        let attachments = images.compactMap(ChatImageAttachment.init(image:))
        let audioClips = audio.flatMap(ChatAudioAttachment.init(snapshot:)).map { [$0] } ?? []
        let audioAttachment = audio.map(UserInput.Audio.from(snapshot:))
        let normalizedText: String
        if trimmed.isEmpty, !images.isEmpty {
            normalizedText = "请描述这张图片。"
        } else if trimmed.isEmpty, audio != nil {
            normalizedText = "请直接转写这段音频内容。"
        } else {
            normalizedText = trimmed
        }
        let requiresMultimodal = !attachments.isEmpty || audioAttachment != nil
        guard !isProcessing else { return }
        guard !normalizedText.isEmpty || !attachments.isEmpty || audioAttachment != nil else { return }
        messages.append(
            ChatMessage(
                role: .user,
                content: displayText,
                images: attachments,
                audios: audioClips
            )
        )
        isProcessing = true

        applySamplingConfig()

        let preflightToolCall = requiresMultimodal ? nil : preflightSkillLoadCall(for: normalizedText)
        let shouldUseFullAgentPrompt =
            !requiresMultimodal
            && (preflightToolCall != nil || shouldUseToolingPrompt(for: normalizedText))
        let activeSkillInfos = shouldUseFullAgentPrompt ? enabledSkillInfos : []
        let historyDepth = requiresMultimodal ? 0 : llm.safeHistoryDepth
        print("[MEM] safeHistoryDepth=\(historyDepth), headroom=\(llm.availableHeadroomMB) MB")
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: attachments)
        print(
            "[VLM] userAttachments=\(attachments.count), promptImages=\(promptImages.count), "
                + "audio=\(audioAttachment == nil ? 0 : 1)"
        )

        messages.append(ChatMessage(role: .assistant, content: "▍"))
        let msgIndex = messages.count - 1

        if requiresMultimodal {
            let multimodalChat: [Chat.Message] = [
                .system(
                    PromptBuilder.multimodalSystemPrompt(
                        hasImages: !promptImages.isEmpty,
                        hasAudio: audioAttachment != nil
                    )
                ),
                .user(
                    normalizedText,
                    images: promptImages.map { .ciImage($0) },
                    audios: audioAttachment.map { [$0] } ?? []
                ),
            ]
            let multimodalContext: [String: any Sendable]? =
                config.enableThinking ? ["enable_thinking": true] : nil
            var multimodalBuffer = ""

            llm.generateStream(chat: multimodalChat, additionalContext: multimodalContext) { [weak self] token in
                guard let self = self else { return }
                multimodalBuffer += token
                let cleaned = self.cleanOutputStreaming(multimodalBuffer)
                self.messages[msgIndex].update(content: (cleaned.isEmpty ? "" : cleaned) + "▍")
            } onComplete: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let fullText):
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? "（无回复）" : cleaned
                    )
                case .failure(let error):
                    log("[Agent] multimodal failed: \(error.localizedDescription)")
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                }
                self.isProcessing = false
            }
            return
        }

        let prompt: String
        if shouldUseFullAgentPrompt {
            prompt = PromptBuilder.build(
                userMessage: normalizedText,
                currentImageCount: attachments.count,
                tools: activeSkillInfos,
                history: messages,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking,
                historyDepth: historyDepth
            )
        } else {
            prompt = PromptBuilder.buildLightweightTextPrompt(
                userMessage: normalizedText,
                history: messages,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking,
                historyDepth: historyDepth
            )
        }
        log("[Agent] text prompt mode=\(shouldUseFullAgentPrompt ? "agent" : "light"), chars=\(prompt.count), skills=\(activeSkillInfos.count)")

        if let preflightToolCall {
            log("[Agent] preflight tool path triggered")
            if messages.indices.contains(msgIndex),
               messages[msgIndex].role == .assistant,
               messages[msgIndex].content == "▍" {
                messages.remove(at: msgIndex)
            }
            await executeToolChain(
                prompt: prompt,
                fullText: preflightToolCall,
                userQuestion: normalizedText,
                images: promptImages
            )
            return
        }

        var detectedToolCall = false
        var buffer = ""
        var bufferFlushed = false

        llm.generateStream(prompt: prompt, images: promptImages, audios: []) { [weak self] token in
            guard let self = self else { return }

            if detectedToolCall {
                buffer += token
                return
            }

            buffer += token

            if buffer.contains("<tool_call>") {
                detectedToolCall = true
                return
            }

            if !bufferFlushed {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return }
                if "<tool_call>".hasPrefix(trimmed) { return }
                bufferFlushed = true
                self.messages[msgIndex].update(content: self.cleanOutputStreaming(buffer))
                return
            }

            let cleaned = self.cleanOutputStreaming(buffer)
            if !cleaned.isEmpty {
                self.messages[msgIndex].update(content: cleaned)
            }
        } onComplete: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fullText):
                log("[Agent] 1st raw: \(fullText.prefix(300))")

                if self.parseToolCall(fullText) != nil {
                    self.messages[msgIndex].update(content: "")
                    Task {
                        await self.executeToolChain(
                            prompt: prompt,
                            fullText: fullText,
                            userQuestion: normalizedText,
                            images: promptImages
                        )
                    }
                    return
                } else {
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? "（无回复）" : cleaned
                    )
                }
            case .failure(let error):
                self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
            }
            self.isProcessing = false
        }
    }

    // MARK: - Skill 结果后的后续推理（支持多轮工具链）

    private func streamLLM(prompt: String, images: [CIImage]) async -> String? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            llm.generateStream(prompt: prompt, images: images, audios: []) { _ in
            } onComplete: { result in
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    log("[Agent] LLM failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func streamLLM(prompt: String, msgIndex: Int, images: [CIImage]) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false
            llm.generateStream(prompt: prompt, images: images, audios: []) { [weak self] token in
                guard let self = self else { return }
                buffer += token

                if toolCallDetected { return }
                if buffer.contains("<tool_call>") {
                    toolCallDetected = true
                    if bufferFlushed && self.messages[msgIndex].role == .assistant {
                        self.messages[msgIndex].update(content: "")
                    }
                    return
                }

                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                }

                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty && self.messages[msgIndex].role == .assistant {
                    self.messages[msgIndex].update(content: cleaned)
                }
            } onComplete: { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func executeToolChain(
        prompt: String,
        fullText: String,
        userQuestion: String,
        images: [CIImage],
        round: Int = 1,
        maxRounds: Int = 10
    ) async {
        guard round <= maxRounds else {
            log("[Agent] 达到最大工具链轮数 \(maxRounds)")
            isProcessing = false
            return
        }

        guard let parsedCall = parseToolCall(fullText) else {
            let cleaned = cleanOutput(fullText)
            if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastAssistant].update(content: cleaned.isEmpty ? "（无回复）" : cleaned)
            }
            isProcessing = false
            return
        }

        let call = (
            name: canonicalToolName(parsedCall.name, arguments: parsedCall.arguments),
            arguments: parsedCall.arguments
        )

        log("[Agent] Round \(round): tool_call name=\(call.name)")

        // ── load_skill ──
        if call.name == "load_skill" {
            let allCalls = parseAllToolCalls(fullText)
            let loadSkillCalls = allCalls.filter { $0.name == "load_skill" }

            var allInstructions = ""
            var loadedDisplayNames: [String] = []
            var loadedSkillIds: [String] = []
            for lsCall in loadSkillCalls {
                let requestedSkillName = (lsCall.arguments["skill"] as? String)
                             ?? (lsCall.arguments["name"] as? String)
                             ?? ""
                let skillName = skillLoader.canonicalSkillId(for: requestedSkillName)
                log("[Agent] load_skill: \(requestedSkillName)")

                let displayName = findDisplayName(for: skillName)
                loadedDisplayNames.append(displayName)
                messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                let cardIdx = messages.count - 1

                guard let instructions = handleLoadSkill(skillName: skillName) else {
                    messages[cardIdx].update(role: .system, content: "done", skillName: displayName)
                    continue
                }

                try? await Task.sleep(for: .milliseconds(300))
                messages[cardIdx].update(role: .system, content: "loaded", skillName: displayName)
                messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: skillName))
                allInstructions += instructions + "\n\n"
                loadedSkillIds.append(skillName)
            }

            guard !allInstructions.isEmpty else {
                isProcessing = false
                return
            }

            if let autoCall = autoToolCallForLoadedSkills(skillIds: loadedSkillIds)
                ?? inferFallbackToolCall(skillIds: loadedSkillIds, userQuestion: userQuestion) {
                log("[Agent] load_skill 直接执行工具: \(autoCall.name)")
                let syntheticToolCall = syntheticToolCallText(
                    name: autoCall.name,
                    arguments: autoCall.arguments
                )
                await executeToolChain(
                    prompt: prompt,
                    fullText: syntheticToolCall,
                    userQuestion: userQuestion,
                    images: images,
                    round: round + 1,
                    maxRounds: maxRounds
                )
                return
            }

            let singleToolExtraction = await extractToolCallForLoadedSkills(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                skillInstructions: allInstructions,
                skillIds: loadedSkillIds,
                images: images
            )
            switch singleToolExtraction {
            case .toolCall(let name, let arguments):
                log("[Agent] load_skill 参数提取后执行工具: \(name)")
                let syntheticToolCall = syntheticToolCallText(name: name, arguments: arguments)
                await executeToolChain(
                    prompt: prompt,
                    fullText: syntheticToolCall,
                    userQuestion: userQuestion,
                    images: images,
                    round: round + 1,
                    maxRounds: maxRounds
                )
                return

            case .needsClarification(let clarification):
                messages.append(ChatMessage(role: .assistant, content: clarification))
                markSkillsDone(loadedDisplayNames)
                isProcessing = false
                return

            case .failed:
                break
            }

            let followUpPrompt = PromptBuilder.buildLoadedSkillPrompt(
                originalPrompt: prompt,
                userQuestion: userQuestion,
                skillInstructions: allInstructions,
                currentImageCount: images.count
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if parseToolCall(nextText) != nil {
                log("[Agent] load_skill 后检测到 tool 调用 (round \(round + 1))")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty
                    || looksLikeStructuredIntermediateOutput(cleaned)
                    || looksLikePromptEcho(cleaned) {
                    let retryPrompt = PromptBuilder.buildLoadedSkillPrompt(
                        originalPrompt: prompt,
                        userQuestion: userQuestion,
                        skillInstructions: allInstructions,
                        currentImageCount: images.count,
                        forceResponse: true
                    )

                    guard let retryText = await streamLLM(prompt: retryPrompt, msgIndex: followUpIndex, images: images) else {
                        isProcessing = false
                        return
                    }

                    if parseToolCall(retryText) != nil {
                        log("[Agent] load_skill 重试后检测到 tool 调用 (round \(round + 1))")
                        messages[followUpIndex].update(content: "")
                        await executeToolChain(
                            prompt: retryPrompt,
                            fullText: retryText,
                            userQuestion: userQuestion,
                            images: images,
                            round: round + 1,
                            maxRounds: maxRounds
                        )
                    } else {
                        let retryCleaned = cleanOutput(retryText)
                        let loadedSkillName = loadedDisplayNames.joined(separator: ", ").isEmpty
                            ? "已加载的能力"
                            : loadedDisplayNames.joined(separator: ", ")
                        let finalReply = retryCleaned.isEmpty
                            || looksLikeStructuredIntermediateOutput(retryCleaned)
                            || looksLikePromptEcho(retryCleaned)
                            ? fallbackReplyForEmptySkillFollowUp(skillName: loadedSkillName)
                            : retryCleaned
                        messages[followUpIndex].update(content: finalReply)
                        markSkillsDone(loadedDisplayNames)
                        isProcessing = false
                    }
                } else {
                    messages[followUpIndex].update(content: cleaned)
                    markSkillsDone(loadedDisplayNames)
                    isProcessing = false
                }
            }
            return
        }

        // ── 具体 Tool 调用 ──

        let ownerSkillId = findSkillId(for: call.name)
        let displayName = findDisplayName(for: call.name)

        let cardIndex: Int
        if let idx = messages.lastIndex(where: {
            $0.role == .system && ($0.skillName == displayName || $0.skillName == call.name)
            && ($0.content == "identified" || $0.content == "loaded")
        }) {
            cardIndex = idx
        } else {
            messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
            cardIndex = messages.count - 1
        }

        guard ownerSkillId != nil else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ 未知工具: \(call.name)"))
            isProcessing = false
            return
        }

        let enabledIds = Set(skillEntries.filter(\.isEnabled).map(\.id))
        guard enabledIds.contains(ownerSkillId!) else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ Skill \(displayName) 未启用"))
            isProcessing = false
            return
        }

        messages[cardIndex].update(role: .system, content: "executing:\(call.name)", skillName: displayName)

        do {
            let toolResult = try await handleToolExecution(toolName: call.name, args: call.arguments)
            let toolResultSummary = toolResultSummaryForModel(toolName: call.name, toolResult: toolResult)
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .skillResult, content: toolResultSummary, skillName: call.name))
            log("[Agent] Tool \(call.name) round \(round) done")

            if shouldSkipToolFollowUpModel(for: call.name) {
                messages.append(ChatMessage(role: .assistant, content: toolResultSummary))
                isProcessing = false
                return
            }

            let followUpPrompt = PromptBuilder.buildToolAnswerPrompt(
                originalPrompt: prompt,
                toolName: call.name,
                toolResultSummary: toolResultSummary,
                userQuestion: userQuestion,
                currentImageCount: images.count
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if !parseAllToolCalls(nextText).isEmpty {
                log("[Agent] 检测到第 \(round + 1) 轮工具调用")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty
                    || looksLikeStructuredIntermediateOutput(cleaned)
                    || looksLikePromptEcho(cleaned) {
                    messages[followUpIndex].update(content: fallbackReplyForEmptyToolFollowUp(
                        toolName: call.name,
                        toolResult: toolResult
                    ))
                } else {
                    messages[followUpIndex].update(content: cleaned)
                }
                isProcessing = false
            }
        } catch {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .system, content: "❌ Tool 执行失败: \(error)"))
            isProcessing = false
        }
    }

    // MARK: - 工具

    func clearMessages() {
        messages.removeAll()
    }

    func cancelActiveGeneration() {
        guard isProcessing || llm.isGenerating else { return }
        llm.cancel()
        isProcessing = false

        if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
            let content = messages[lastAssistant].content.replacingOccurrences(of: "▍", with: "")
            messages[lastAssistant].update(content: content.isEmpty ? "（已中断）" : content)
        }

        log("[Agent] Generation cancelled because the app left foreground")
    }

    private func promptImages(
        historyDepth: Int,
        currentImages: [ChatImageAttachment]
    ) -> [CIImage] {
        _ = historyDepth
        return Array(currentImages.prefix(1).compactMap(\.ciImage))
    }

    func setAllSkills(enabled: Bool) {
        for i in skillEntries.indices {
            skillEntries[i].isEnabled = enabled
        }
    }

    // MARK: - 解析

    private func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        return parseAllToolCalls(text).first
    }

    private func parseAllToolCalls(_ text: String) -> [(name: String, arguments: [String: Any])] {
        var results: [(name: String, arguments: [String: Any])] = []
        let patterns = [
            "<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>",
            "```json\\s*(\\{.*?\\})\\s*```",
            "<function_call>\\s*(\\{.*?\\})\\s*</function_call>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let jsonRange = Range(match.range(at: 1), in: text) {
                    let json = String(text[jsonRange])
                    if let data = json.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = dict["name"] as? String {
                        results.append((name, dict["arguments"] as? [String: Any] ?? [:]))
                    }
                }
            }
            if !results.isEmpty { break }
        }
        return results
    }

    private func extractSkillName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"name\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[nameRange])
    }

    private func cleanOutputStreaming(_ text: String) -> String {
        var result = preserveThinkingChannels(in: text)

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

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
        return normalizeSafetyTruncation(in: result)
    }

    private func cleanOutput(_ text: String) -> String {
        var result = preserveThinkingChannels(in: text)

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        if let lastOpen = result.lastIndex(of: "<") {
            let tail = String(result[lastOpen...])
            let tailBody = tail.dropFirst()
            if !tailBody.isEmpty && tailBody.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "/" || $0 == "|" }) {
                result = String(result[result.startIndex..<lastOpen])
            }
        }

        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            result = ""
        } else if result.hasPrefix("user\n") {
            result = String(result.dropFirst(5))
        } else if result == "user" {
            result = ""
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizeSafetyTruncation(in: result)
    }

    private func normalizeSafetyTruncation(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let warningRange = trimmed.range(of: "> ⚠️ ") else {
            return trimmed
        }

        let body = String(trimmed[..<warningRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let warning = String(trimmed[warningRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return warning }

        let normalizedBody = trimIncompleteTrailingBlock(in: body)
        guard !normalizedBody.isEmpty else { return warning }
        return normalizedBody + "\n\n" + warning
    }

    private func trimIncompleteTrailingBlock(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let paragraphBreak = trimmed.range(of: "\n\n", options: .backwards) {
            let tailLength = trimmed.distance(from: paragraphBreak.upperBound, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 280 {
                return String(trimmed[..<paragraphBreak.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let sentenceBoundary = lastSentenceBoundary(in: trimmed) {
            let tailLength = trimmed.distance(from: sentenceBoundary, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 220 {
                return String(trimmed[..<sentenceBoundary])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private func lastSentenceBoundary(in text: String) -> String.Index? {
        let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if sentenceEndings.contains(text[index]) {
                return text.index(after: index)
            }
        }
        return nil
    }

    private func preserveThinkingChannels(in text: String) -> String {
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

            let thoughtStart = openRange.lowerBound
            let contentStart = text.index(thoughtStart, offsetBy: token.count)
            if let closeRange = text.range(of: closeToken, range: contentStart..<text.endIndex) {
                result += text[contentStart..<closeRange.lowerBound]
                result += thinkingCloseMarker
                cursor = closeRange.upperBound
            } else {
                result += text[contentStart..<text.endIndex]
                break
            }
        }

        return result
    }
}
