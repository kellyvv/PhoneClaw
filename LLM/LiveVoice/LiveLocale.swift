import Foundation

// MARK: - Live 语音模式 i18n 配置
//
// 设计目标: LIVE flow 代码全部用 `LiveLocale.zhCN.config` 这个固定入口。
// 真正的语言切换发生在 `.config` getter 内部 — 它读 LanguageService,
// 系统语言中文返回 .zhCN 数据, 英文返回 .enUS 数据, 日语返回 .jaJP 数据。这样保持 LIVE flow
// 文件 (LiveModeEngine / LiveModeUI / LiveTurnProcessor) 少量改动,
// 同时让 zh / en 走各自的 prompt + persona + 状态文案。
//
// 关键设计点:
//   1. 各语言 prompt 资产完全独立, 不混读。
//   2. PersonaName 各 locale 单语: 中文 "手机龙虾", 英文/日文 "PhoneClaw"。
//   3. PromptBuilder.buildLiveVoiceUserPrompt 拼"persona 提醒"前缀时,
//      用 locale 自己的 userPromptPrefix ("你是" / "You are"), 不再硬编码中文。

enum LiveLocale: String, Sendable {
    case zhCN = "zh-CN"

    /// LIVE flow 调用 `LiveLocale.zhCN.config` 的地方都走这个 getter。
    /// 实际返回哪份数据看 `LanguageService.shared.current` — 生效语言中文拿 .zhCN,
    /// 英文拿 .enUS, 日语拿 .jaJP。case 维持一个 `.zhCN` 是因为 LIVE flow 大量代码
    /// 已经写死了 `LiveLocale.zhCN` / `locale: .zhCN`, 改 enum 形状就要碰
    /// LIVE flow 文件 (跟"流程不改"边界冲突)。让 case 退化成"locale 入口",
    /// 用一个 dynamic getter 换 call site 全部不动。
    var config: LiveLocaleConfig {
        switch LanguageService.shared.current.resolved {
        case .zhHans: return .zhCNData
        case .en:     return .enUSData
        case .ja:     return .jaJPData
        case .auto:   return .zhCNData  // 不可能, .auto 在 LanguageService 里已经被 resolve 掉
        }
    }
}

// MARK: - LiveLocaleConfig

/// 单一 locale 的全部 Live prompt 资产. 所有 string 在该 locale 内自洽,
/// 不依赖其它 locale 的常量.
struct LiveLocaleConfig: Sendable {

    struct StatusStrings: Sendable {
        let preparingPrefix: String
        let preparingLive: String
        let preparing: String
        let liveModelMissing: String
        let audioEngineFailed: String
        let vadUnavailable: String
        let recording: String
        let processing: String
        let listeningPrompt: String
        let loadModelFirst: String
        let initializationFailed: String
        let ended: String
        let speaking: String
        let loadingHeadline: String
        let listeningHeadline: String
        let recordingHeadline: String
        let processingHeadline: String
        let speakingHeadline: String
        let interruptHint: String
    }

    /// LLM 在 Live 自我介绍用的名字. TTS 友好 — 单语, 无英文混读.
    let personaName: String

    /// Live 唯一的 system prompt. 进入 Live 时一次性注入。
    let systemPrompt: String

    /// Live 启动后用于预热 conversation 的首条 user turn.
    let greetingPrompt: String

    /// LiveModeEngine 收到 unexpected tool_call 时, TTS 朗读的口语兜底.
    let fallbackUtterance: String

    /// PromptBuilder 在每轮 user prompt 前面加的"persona 提醒"前缀。
    /// **包含 locale 需要的尾部空格**（英文需要 "You are " 后空格, 中文不需要）,
    /// 这样模板可以写成 `(\(prefix)\(persona))` 不再做语言判断:
    ///   - 中文 "你是"     → 拼出 "(你是手机龙虾) 用户的话"
    ///   - 英文 "You are " → 拼出 "(You are PhoneClaw) what user said"
    let userPromptPrefix: String

    /// 视觉轮 (带摄像头画面) 注入的轻量 task hint — 按 locale 本地化。
    let visionTaskHint: String

    /// camera-off marker — 本会话开过摄像头但当前已关时注入。
    /// 必须跟该 locale 的 systemPrompt 里要求模型识别的标记一致。
    let cameraOffMarker: String

    /// Live 状态/提示相关文案。
    let statusStrings: StatusStrings
}

// MARK: - 中文 (zh-CN) 数据

extension LiveLocaleConfig {

    static let zhCNData = LiveLocaleConfig(
        personaName: "手机龙虾",
        systemPrompt: """
        你叫"手机龙虾"，是用户手机上的本地语音助手。
        你正在和用户进行实时语音对话。
        判断用户这句是否说完整：完整就在第一字符输出"✓"加空格再回答；像被打断只输出"○"；像在思考只输出"◐"。"○"和"◐"后不能再输出任何字。
        回答用自然中文口语，长度按语境决定：简单问题一句话说清；需要解释、介绍或描述画面时可以两三句。不要为了显得完整而扩写，也不要列表，除非用户明确要求。
        如果用户问的是"你能做什么"之类的介绍性问题，给具体例子，但保持适合语音播放的长度。
        你有摄像头能力，但默认是关闭的。只要本轮用户消息附带画面，就说明摄像头当前开启；这种视觉轮次通常视为完整问题，请以"✓"开头，按画面内容简短回答，必要时补充一两句细节。描述画面时用第一人称"我看到..."，或者直接描述画面内容；不要说"你看到..."。只有用户文本里明确出现"(摄像头未开启)"时，才说明当前没有画面，不要声称能看到东西。
        """,
        greetingPrompt: "请只输出这一句开场白：✓ 我是手机龙虾，请问你需要做什么。不要解释，不要换行，不要添加其他内容。",
        fallbackUtterance: "抱歉，我刚才没听清，麻烦再说一次。",
        userPromptPrefix: "你是",
        visionTaskHint: "(本轮已附带摄像头画面；请以✓开头，用“我看到”或直接描述画面，不要说“你看到”；简短回答，必要时补充细节) ",
        cameraOffMarker: "(摄像头未开启) ",
        statusStrings: StatusStrings(
            preparingPrefix: "正在准备",
            preparingLive: "正在准备语音对话",
            preparing: "正在准备",
            liveModelMissing: "请先在配置页下载语音模型",
            audioEngineFailed: "音频引擎启动失败",
            vadUnavailable: "语音检测不可用",
            recording: "正在听你说",
            processing: "正在理解",
            listeningPrompt: "我在听，请说话",
            loadModelFirst: "请先加载模型",
            initializationFailed: "语音模式初始化失败",
            ended: "语音对话已结束",
            speaking: "正在回答",
            loadingHeadline: "正在加载",
            listeningHeadline: "我在听",
            recordingHeadline: "正在听你说",
            processingHeadline: "正在理解",
            speakingHeadline: "正在回答",
            interruptHint: "可以直接打断"
        )
    )

    /// Backward-compat alias. LiveVoiceConstants 还引用 `.zhCN`, 保留指针。
    static var zhCN: LiveLocaleConfig { zhCNData }

    // MARK: - 英文 (en-US) 数据

    static let enUSData = LiveLocaleConfig(
        personaName: "PhoneClaw",
        systemPrompt: """
        You are an on-device voice assistant called PhoneClaw, running locally on the user's phone.
        You are having a real-time voice conversation with the user.

        Decide whether the user's utterance is complete: if it is complete, output "✓" then a space then your reply at the very start; if the user got cut off, output only "○"; if the user is still thinking, output only "◐". After "○" or "◐" output no further characters.

        Reply in natural conversational English. Let the context decide the length: answer simple requests in one sentence; use two or three sentences when explaining, introducing capabilities, or describing an image. Do not pad the answer just to sound complete, and do not use lists unless the user asks.

        IMPORTANT — sentence openers: never begin a reply with the bare word "PhoneClaw". Always start with natural English: "I'm", "I", "Hi", "Hey", "Sure", "Yes", "Of course", "Let me", etc. When introducing yourself, say "I'm PhoneClaw, ..." or "Hi, I'm PhoneClaw — ..." but do NOT start with "PhoneClaw" alone.

        For introductory questions like "what can you do", give concrete examples while keeping the reply suitable for voice playback.

        You have camera capability, but it is off by default. If the current user turn includes an image, the camera is currently on; treat that visual turn as complete unless the wording is clearly unfinished, start with "✓", and answer from the image concisely, adding one or two details when useful. When describing the image, use first person ("I can see...") or describe the scene directly; do not say "you see...". Only when the user text explicitly contains "(camera off)" should you treat the camera as unavailable and avoid claiming you can see anything.
        """,
        greetingPrompt: "Output exactly this opening line: ✓ I'm PhoneClaw. What do you need? Do not add anything else.",
        fallbackUtterance: "Sorry, I didn't catch that. Could you say it again?",
        // 英文留空 — 不再加 (You are PhoneClaw) 这个 per-turn 提醒。
        // 中文里 (你是手机龙虾) 是自然语序模型不会当 label, 但英文 "(You are PhoneClaw)"
        // 在 Gemma E2B 英文模式下被当成 stage direction, 强化了"以 PhoneClaw 开头答复"的鹦鹉模式。
        // 系统 prompt 已经在 conversation 开场注入并保留在 KV cache 里, 不需要每轮再提醒。
        userPromptPrefix: "",
        visionTaskHint: "(camera frame attached; start with ✓; answer as what I can see or describe the scene directly, not as what the user sees) ",
        cameraOffMarker: "(camera off) ",
        statusStrings: StatusStrings(
            preparingPrefix: "Preparing",
            preparingLive: "Preparing voice mode",
            preparing: "Preparing",
            liveModelMissing: "Please download voice models in Settings first",
            audioEngineFailed: "Audio engine failed to start",
            vadUnavailable: "Voice detection unavailable",
            recording: "Listening",
            processing: "Thinking",
            listeningPrompt: "I'm listening, go ahead",
            loadModelFirst: "Please load the model first",
            initializationFailed: "Voice mode init failed",
            ended: "Voice mode ended",
            speaking: "Replying",
            loadingHeadline: "Loading",
            listeningHeadline: "I'm listening",
            recordingHeadline: "Listening",
            processingHeadline: "Thinking",
            speakingHeadline: "Replying",
            interruptHint: "You can interrupt me"
        )
    )

    // MARK: - 日本語 (ja-JP) 数据

    static let jaJPData = LiveLocaleConfig(
        personaName: "PhoneClaw",
        systemPrompt: """
        あなたは「PhoneClaw」、ユーザーのスマホ上で動くローカル音声アシスタントです。
        ユーザーとリアルタイムの音声会話をしています。

        ユーザーの発話が言い終わっているか判断してください: 言い終わっていれば、先頭に「✓」と半角スペースを出力してから返答します; 途中で切れたようなら「○」だけを出力します; まだ考えている様子なら「◐」だけを出力します。「○」や「◐」の後には一切何も出力しないでください。

        返答は自然な話し言葉の日本語で。長さは文脈で決めます: 簡単な質問は一文で; 説明・自己紹介・画面の描写が必要なときは二、三文で。完結に見せるための水増しはせず、ユーザーが明示的に求めない限りリストは使いません。

        明るくフレンドリーな口調で、ただし簡潔に保ちます。

        「何ができるの?」のような紹介的な質問には、具体例を挙げつつ、音声で聞いて心地よい長さに収めます。

        カメラ機能がありますが、既定ではオフです。今回のユーザー発話に画像が付いていれば、カメラは今オンです; その視覚ターンは、言い回しが明らかに未完でない限り完結とみなし、「✓」で始め、画面の内容から簡潔に答え、必要なら一、二点の詳細を添えます。画面を描写するときは一人称で「〜が見えます」と言うか、内容を直接述べます;「あなたには〜が見えます」とは言いません。ユーザーのテキストに明示的に「(カメラオフ)」と書かれている場合のみ、今は画面がないものとして扱い、見えていると主張しないでください。
        """,
        greetingPrompt: "次の一行をそのまま出力してください: ✓ PhoneClaw です。何をお手伝いしましょうか? 説明や改行、他の内容は加えないでください。",
        fallbackUtterance: "ごめんなさい、うまく聞き取れませんでした。もう一度言ってもらえますか?",
        // 日本語も英文と同様に per-turn の "(あなたは…)" 前置きを付けない。
        userPromptPrefix: "",
        visionTaskHint: "(カメラ画像が添付されています; ✓で始め、「〜が見えます」と一人称で、または画面を直接描写してください;「あなたには〜が見えます」とは言わない; 簡潔に、必要なら詳細を補足) ",
        cameraOffMarker: "(カメラオフ) ",
        statusStrings: StatusStrings(
            preparingPrefix: "準備中",
            preparingLive: "音声会話を準備中",
            preparing: "準備中",
            liveModelMissing: "先に設定で音声モデルをダウンロードしてください",
            audioEngineFailed: "オーディオエンジンの起動に失敗しました",
            vadUnavailable: "音声検出を利用できません",
            recording: "聞いています",
            processing: "理解しています",
            listeningPrompt: "聞いています、どうぞ話してください",
            loadModelFirst: "先にモデルを読み込んでください",
            initializationFailed: "音声モードの初期化に失敗しました",
            ended: "音声会話を終了しました",
            speaking: "応答中",
            loadingHeadline: "読み込み中",
            listeningHeadline: "聞いています",
            recordingHeadline: "聞いています",
            processingHeadline: "理解しています",
            speakingHeadline: "応答中",
            interruptHint: "いつでも話しかけてOK"
        )
    )
}
