import Foundation
import SwiftUI

// MARK: - PhoneClaw Language Service
//
// 单一语言入口。全 app 不再各自写 `Locale.preferredLanguages.contains { $0.hasPrefix("zh") }`,
// 统一通过 `LanguageService.shared.current.resolved` 拿到生效语言 (zhHans / en / ja)。
//
// 设计约束:
//   - `.auto` 是 default, resolve 时看系统 locale (行为类似微信: 默认跟系统)
//   - 用户可在配置页手动覆盖成 `.zhHans` / `.en` / `.ja`
//   - 切换立即生效, SwiftUI 视图通过 @Observable 自动重渲染
//   - 会话边界: 语言切换只影响下一次新开会话, 当前对话不动 (AgentEngine 读 current 时快照)
//
// 不包含:
//   - 运行时切换时清空已生成对话 — 用户可能正在翻阅历史, 不触发破坏性操作

// MARK: - AppLanguage

/// 用户可选的语言偏好。`.auto` 走系统 locale, 其它几个是硬覆盖。
enum AppLanguage: String, CaseIterable, Codable {
    case auto   = "auto"
    case zhHans = "zh-Hans"
    case en     = "en"
    case ja     = "ja"

    /// 配置页 Picker 的显示名。`.auto` 显示名自身依赖当前语言, 所以用 `tr()`。
    var displayName: String {
        switch self {
        case .auto:   return tr("自动", "Auto", "自動")
        case .zhHans: return "中文"
        case .en:     return "English"
        case .ja:     return "日本語"
        }
    }
}

// MARK: - LocalizationContext

/// 一次生效的语言解析结果。`raw` 保留用户的选择 (含 `.auto`);
/// `resolved` 永远是具体语言 (`.zhHans` / `.en` / `.ja`), 不会是 `.auto` — UI 和 prompt 用这个。
struct LocalizationContext: Equatable {
    let raw: AppLanguage
    let resolved: AppLanguage

    var isChinese: Bool { resolved == .zhHans }
    var isEnglish: Bool { resolved == .en }
    var isJapanese: Bool { resolved == .ja }

    var localeIdentifier: String {
        switch resolved {
        case .zhHans: return "zh-Hans"
        case .ja: return "ja"
        default: return "en"
        }
    }
}

// MARK: - LanguageService

/// 全局语言状态。`@Observable` — SwiftUI 视图在 `body` 里读 `shared.current`
/// 会自动建立 observation 依赖, 切换时触发 re-render。
@Observable
final class LanguageService {

    static let shared = LanguageService()

    private static let defaultsKey = "PhoneClaw.appLanguage"

    /// 当前生效的语言上下文。读这个值即可, 无需再问 Locale。
    private(set) var current: LocalizationContext

    /// 用户在配置页选择的原值 (含 `.auto`). 设置会自动持久化到 UserDefaults
    /// 并重新 resolve, 触发所有依赖视图刷新。
    var selected: AppLanguage {
        get { current.raw }
        set {
            guard newValue != current.raw else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
            current = Self.resolve(raw: newValue)
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
                                          .flatMap(AppLanguage.init(rawValue:))
        self.current = Self.resolve(raw: stored ?? .auto)
    }

    /// Process-local language override for CLI harnesses and diagnostics.
    /// Unlike `selected`, this does not persist to UserDefaults.
    func setTemporaryLanguageForCurrentProcess(_ language: AppLanguage) {
        current = Self.resolve(raw: language)
    }

    /// 根据 raw 选择计算 resolved 语言。`.auto` 走系统 preferred languages,
    /// 看首选语言前缀: `zh` → 中文, `ja` → 日语, 其它一律英文。
    private static func resolve(raw: AppLanguage) -> LocalizationContext {
        let resolved: AppLanguage
        switch raw {
        case .auto:
            // 只看首选语言, 不用 `contains`: 用户主语言英文但备用语言有中文时, 应保持英文。
            // `lowercased()`: iOS 通常返回小写 ("zh-hans"), 但不同平台/模拟器配置可能
            // 返回大小写混合, 先归一化避免边界踩坑。
            let first = Locale.preferredLanguages.first?.lowercased() ?? ""
            if first.hasPrefix("zh") {
                resolved = .zhHans
            } else if first.hasPrefix("ja") {
                resolved = .ja
            } else {
                resolved = .en
            }
        case .zhHans, .en, .ja:
            resolved = raw
        }
        return LocalizationContext(raw: raw, resolved: resolved)
    }
}

// MARK: - Japanese fallback localization

/// Temporary centralized ja fallback for call sites that still pass only zh/en.
/// Explicit `tr(..., ..., ja)` always wins; this table only prevents Japanese UI
/// from falling back to English while the app moves toward fully keyed strings.
private enum JapaneseFallbackLocalization {
    private static let exact: [String: String] = [
        "Ask anything...": "何でも聞いてください…",
        "Create tomorrow's meeting": "明日の会議を作成",
        "Remind me at 8pm": "今夜8時にリマインド",
        "Add a contact": "連絡先を追加",
        "Read my clipboard": "クリップボードを読む",
        "Show today's steps": "今日の歩数を見る",
        "Translate this sentence": "この文を翻訳",
        "Write an article": "文章を書く",
        "Please write an article of about 800 words on the topic: why local AI will become an important capability on phones. Make it clearly structured, natural in tone, include section headings, and end with three key takeaways.": "ローカルAIがスマホの重要な機能になる理由について、800字前後の記事を書いてください。構成を分かりやすく、自然な語り口で、小見出しを入れ、最後に3つの要点をまとめてください。",
        "Schedule": "予定を入れる",
        "Schedule a product meeting for tomorrow at 2 PM.": "明日の午後2時にプロダクト会議を予定に入れてください。",
        "Today's activity": "今日の活動量",
        "How is my activity today?": "今日の活動量はどうですか?",
        "Web search": "Web検索",
        "Search the web: latest artificial intelligence news": "Webで検索: 最新の人工知能ニュース",
        "Analyze image": "画像を分析",
        "Please analyze this image and tell me the key content, possible issues, and next-step suggestions.": "この画像を分析して、主な内容、考えられる問題、次の提案を教えてください。",
        "Voice models not ready": "音声モデルが未準備です",
        "Not now": "あとで",
        "Download": "ダウンロード",
        "Tell me more": "詳しく教えて",
        "Tell me more about your last answer.": "直前の回答をもう少し詳しく説明してください。",
        "Give an example": "例を挙げて",
        "Give me a concrete example.": "具体例を1つ挙げてください。",
        "Summarize": "要約",
        "Summarize that in three points.": "今の内容を3点にまとめてください。",
        "Current model does not support Thinking mode": "現在のモデルは思考モードに対応していません",
        "Current model does not support LIVE": "現在のモデルはLIVEに対応していません",
        "Thinking mode on": "思考モード オン",
        "Thinking mode off": "思考モード オフ",
        "New chat": "新しい会話",
        "New Chat": "新しい会話",
        "History": "履歴",
        "Thinking mode": "思考モード",
        "On": "オン",
        "Off": "オフ",
        "Settings": "設定",
        "Switching model": "モデルを切り替え中",
        "Unloading model": "モデルを解放中",
        "Preparing model download": "モデルのダウンロードを準備中",
        "Downloading model": "モデルをダウンロード中",
        "Preparing model": "モデルを準備中",
        "Loading model": "モデルを読み込み中",
        "Opening session": "セッションを開いています",
        "Model download failed": "モデルのダウンロードに失敗しました",
        "Model load failed": "モデルの読み込みに失敗しました",
        "Photo": "写真",
        "Stop": "停止",
        "Record": "録音",
        "File": "ファイル",
        "Download a model first": "先にモデルをダウンロードしてください",
        "Preparing...": "準備中...",
        "Release to Stop": "離して終了",
        "Hold to Talk": "長押しで話す",
        "Audio File": "音声ファイル",
        "%.1f s · %d kHz": "%.1f 秒 · %d kHz",
        "\n...(truncated)": "\n...(省略)",
        "Delete": "削除",
        "No History": "履歴はありません",

        "Model Settings": "モデル設定",
        "Model": "モデル",
        "Prompt": "プロンプト",
        "Access": "権限",
        "Skills": "スキル",
        "Privacy": "プライバシー",
        "Cancel": "キャンセル",
        "OK": "OK",
        "System Prompt": "システムプロンプト",
        "Restore Default": "デフォルトに戻す",
        "No model selected": "モデル未選択",
        "Models": "モデル",
        "Recommended": "おすすめ",
        "Stronger": "高性能",
        "Vision+": "視覚強化",
        "Resume": "再開",
        "Download Recommended": "おすすめモデルをダウンロード",
        "No Model Selected": "モデル未選択",
        "Model Pending Download": "モデルは未ダウンロードです",
        "Loaded Model": "読み込み済みモデル",
        "Selected Model": "選択中のモデル",
        "Loaded": "読み込み済み",
        "Loading": "読み込み中",
        "Switching": "切り替え中",
        "Downloaded": "ダウンロード済み",
        "Not downloaded": "未ダウンロード",
        "Not downloaded · resumable": "未ダウンロード · 再開可能",
        "Not downloaded · Resume available": "未ダウンロード · 再開可能",
        "Checking": "確認中",
        "Downloading": "ダウンロード中",
        "Download failed": "ダウンロード失敗",
        "Download failed. Please try again.": "ダウンロードに失敗しました。もう一度お試しください。",
        "Select a model": "モデルを選択してください",
        "Choose an installed model, or download the current model first.": "インストール済みのモデルを選択するか、現在のモデルを先にダウンロードしてください。",
        "Available after download": "ダウンロード後に利用できます",
        "Unloading": "解放中",
        "Inference": "推論",
        "Inference Mode": "推論方式",
        "Speculative Decoding": "推測デコード",
        "Voice": "音声",
        "Live Voice Models": "リアルタイム音声モデル",
        "Resume Download": "ダウンロードを再開",
        "Remove": "削除",
        "Bundled": "内蔵",
        "Retry": "再試行",
        "Downloaded to device.": "端末にダウンロード済みです。",
        "Permissions": "権限",
        "Requesting": "リクエスト中",
        "Request": "リクエスト",
        "Microphone": "マイク",
        "Camera": "カメラ",
        "Calendar Write": "カレンダー書き込み",
        "Calendar Read": "カレンダー読み取り",
        "Reminders": "リマインダー",
        "Contacts": "連絡先",
        "Health Data": "ヘルスケアデータ",
        "Not Requested": "未リクエスト",
        "Denied": "拒否済み",
        "Restricted": "制限中",
        "Granted": "許可済み",
        "The system permission dialog will appear on first use": "初回使用時にシステムの権限ダイアログが表示されます",
        "Please enable this permission manually in Settings": "設定でこの権限を手動で有効にしてください",
        "This permission is restricted on the current device": "この端末ではこの権限が制限されています",
        "Related skills can run directly": "関連スキルを直接実行できます",
        "Local-first": "ローカル優先",
        "Model Downloads": "モデルダウンロード",
        "Tracking": "トラッキング",
        "Privacy Policy": "プライバシーポリシー",
        "Close": "閉じる",
        "Enabled Model": "有効なモデル",
        "The model in use. Changes apply after tapping OK.": "使用中のモデルです。変更はOKを押すと反映されます。",
        "Models must be downloaded before they can be selected.": "モデルは選択する前にダウンロードが必要です。",
        "Live voice and hold-to-talk require speech recognition, speech synthesis, and voice detection models.": "リアルタイム音声と長押しで話す機能には、音声認識、音声合成、音声検出モデルが必要です。",
        "Controls how the model generates responses.": "モデルの応答生成方式を制御します。",
        "GPU is usually faster; CPU usually uses less memory.": "GPUは通常高速で、CPUは通常メモリ使用量を抑えます。",
        "Available for Gemma 4 only. Some short replies may be faster. Off by default.": "Gemma 4のみ利用できます。一部の短い返信が速くなる場合があります。既定ではオフです。",
        "Defaults to system. Manual changes update the interface immediately and apply to new chats.": "既定ではシステム設定に従います。手動で変更するとインターフェイスはすぐ切り替わり、新しい会話に適用されます。",
        "Controls default behavior and tone. Changes apply after tapping OK.": "助手の既定の振る舞いと口調を制御します。変更はOKを押すと反映されます。",
        "Permissions allow related skills to access system capabilities.": "権限を許可すると、関連スキルがシステム機能にアクセスできます。",
        "Used for recording and live voice input.": "録音とリアルタイム音声入力に使用します。",
        "Used by Live mode to observe the surroundings.": "Liveモードで周囲を把握するために使用します。",
        "Used to create and write calendar events.": "カレンダー予定の作成と書き込みに使用します。",
        "Used to read calendar events in a chosen time range for local schedule analysis.": "指定した期間の予定を読み取り、端末内でスケジュール分析するために使用します。",
        "Used to create reminders and tasks.": "リマインダーやタスクの作成に使用します。",
        "Used to save and update contacts.": "連絡先の保存と更新に使用します。",
        "Used to read steps, distance, active energy, heart rate, sleep, workouts, weight, and HRV for local summaries.": "歩数、距離、活動エネルギー、心拍数、睡眠、運動、体重、HRVを読み取り、端末内で要約するために使用します。",
        "Chat, writing, tools, LIVE": "チャット、文章作成、ツール、LIVE",
        "Complex tasks and multi-tool planning": "複雑なタスクと複数ツールの計画",
        "Complex image analysis and vision assist": "複雑な画像分析と視覚支援",
        "Allow recording and capturing realtime audio input": "録音とリアルタイム音声入力の取得を許可",
        "Allow camera access for Live mode visual grounding": "Liveモードの視覚理解のためにカメラアクセスを許可",
        "Allow creating and writing calendar events": "カレンダー予定の作成と書き込みを許可",
        "Allow reading calendar events for local analysis": "端末内分析のために予定の読み取りを許可",
        "Allow creating reminders and tasks": "リマインダーとタスクの作成を許可",
        "Allow saving and updating contacts": "連絡先の保存と更新を許可",
        "Allow reading steps, heart rate, sleep, weight, and other Health data": "歩数、心拍数、睡眠、体重などのヘルスケアデータ読み取りを許可",

        "Enabled": "有効",
        "No skills available": "利用可能なスキルはありません",
        "All skills are enabled": "すべてのスキルが有効です",
        "All skills are disabled": "すべてのスキルが無効です",
        "Enable All": "すべて有効",
        "Disable All": "すべて無効",
        "Bulk Actions": "一括操作",
        "Done": "完了",
        "Tools": "ツール",
        "Ready": "利用可能",
        "Missing": "不足",
        "Parameters:": "パラメータ:",
        "Example": "例",
        "Instructions": "指示",
        "Source": "ソース",
        "Save": "保存",
        "Edit": "編集",
        "Hide": "閉じる",
        "View": "表示",
        "Saved": "保存済み",
        "Enabled skills are available to the assistant.": "有効なスキルは助手が利用できます。",
        "Enable only what you need so the assistant stays focused.": "必要なスキルだけを有効にすると、助手が集中しやすくなります。",

        "Regenerate": "再生成",
        "Captured thinking content": "思考内容を取得しました",
        "Think": "思考",
        "Created Event": "予定を作成しました",
        "Created Reminder": "リマインダーを作成しました",
        "Searched Contacts": "連絡先を検索しました",
        "Saved Contact": "連絡先を保存しました",
        "Deleted Contact": "連絡先を削除しました",
        "Updated Clipboard": "クリップボードを更新しました",
        "Read Clipboard": "クリップボードを読み取りました",
        "Generated Health Report": "健康レポートを生成しました",
        "Read Sleep": "睡眠を読み取りました",
        "Read Workouts": "運動記録を読み取りました",
        "Read Weight": "体重を読み取りました",
        "Read Distance": "距離を読み取りました",
        "Read Active Energy": "活動エネルギーを読み取りました",
        "Read Heart Rate": "心拍数を読み取りました",
        "Read Steps": "歩数を読み取りました",
        "Translation Ready": "翻訳完了",
        "Used Calendar": "カレンダーを使用しました",
        "Used Reminders": "リマインダーを使用しました",
        "Used Contacts": "連絡先を使用しました",
        "Read Health Data": "ヘルスケアデータを読み取りました",
        "Creating Event…": "予定を作成中…",
        "Creating Reminder…": "リマインダーを作成中…",
        "Searching Contacts…": "連絡先を検索中…",
        "Saving Contact…": "連絡先を保存中…",
        "Deleting Contact…": "連絡先を削除中…",
        "Updating Clipboard…": "クリップボードを更新中…",
        "Reading Clipboard…": "クリップボードを読み取り中…",
        "Generating Health Report…": "健康レポートを生成中…",
        "Reading Sleep…": "睡眠を読み取り中…",
        "Reading Workouts…": "運動記録を読み取り中…",
        "Reading Weight…": "体重を読み取り中…",
        "Reading Distance…": "距離を読み取り中…",
        "Reading Active Energy…": "活動エネルギーを読み取り中…",
        "Reading Heart Rate…": "心拍数を読み取り中…",
        "Reading Steps…": "歩数を読み取り中…",
        "Using Calendar…": "カレンダーを使用中…",
        "Using Reminders…": "リマインダーを使用中…",
        "Using Contacts…": "連絡先を使用中…",
        "Reading Health Data…": "ヘルスケアデータを読み取り中…",
        "Translating…": "翻訳中…",
        "Understand request": "依頼を理解",
        "Prepare skill": "スキルを準備",
        "Run skill": "スキルを実行",
        "Compose reply": "返信を整理",

        "Camera Access Needed": "カメラ権限が必要です",
        "Open Settings": "設定を開く",
        "Listening": "聞き取り中",
        "You": "あなた",
        "Stop Camera": "カメラを停止",
        "Start Camera": "カメラを開始",
        "End": "終了",

        "Download progress found. You can resume downloading.": "ダウンロード進捗があります。再開できます。",
        "PhoneClaw processes chat, image understanding, voice, and tool execution locally by default. Chat content, images, and personal data are not uploaded to PhoneClaw servers.": "PhoneClawは既定でチャット、画像理解、音声、ツール実行を端末内で処理します。チャット内容、画像、個人データはPhoneClawサーバーへアップロードされません。",
        "Microphone, camera, calendar, reminders, contacts, and Health data are accessed only when you enable related features. Health data is read-only and used locally for summaries and insights.": "マイク、カメラ、カレンダー、リマインダー、連絡先、ヘルスケアデータは、関連機能を有効にした場合のみアクセスされます。ヘルスケアデータは読み取り専用で、端末内の要約と提案に使用されます。",
        "When you choose to download a model, the app connects to model sources to fetch model files. These downloads are model data, not executable code, and are stored on device.": "モデルのダウンロードを選択すると、アプリはモデル配布元に接続してモデルファイルを取得します。ダウンロードされるのはモデルデータであり、実行コードではなく、端末内に保存されます。",
        "PhoneClaw does not use App Tracking Transparency tracking and does not use your data to track you across apps or websites.": "PhoneClawはApp Tracking Transparencyによる追跡を使用せず、アプリやWebサイトをまたいでユーザーを追跡する目的でデータを使用しません。",
        "This summary explains how PhoneClaw handles data locally on device and when it accesses system permissions.": "この概要では、PhoneClawが端末内でデータを処理する方法と、システム権限へアクセスするタイミングを説明します。",
    ]

    static func text(zh: String, en: String) -> String? {
        if let value = exact[en] { return value }
        if let dynamic = dynamicText(en: en) { return dynamic }
        return nil
    }

    private static func dynamicText(en: String) -> String? {
        if en.hasPrefix("Voice input and LIVE need a voice model download, about "),
           en.hasSuffix(" MB.") {
            let amount = en
                .replacingOccurrences(of: "Voice input and LIVE need a voice model download, about ", with: "")
                .replacingOccurrences(of: " MB.", with: "")
            return "音声入力とLIVEには音声モデルのダウンロードが必要です。約\(amount)MBです。"
        }
        if en.hasPrefix("Downloading model ") {
            return en.replacingOccurrences(of: "Downloading model", with: "モデルをダウンロード中")
        }
        if en.hasPrefix("Downloaded · ") {
            return "ダウンロード済み · \(localizedFragment(String(en.dropFirst("Downloaded · ".count))))"
        }
        if en.hasPrefix("Downloading · ") {
            return "ダウンロード中 · \(String(en.dropFirst("Downloading · ".count)))"
        }
        if en.hasPrefix("Not downloaded · resumable · ") {
            return "未ダウンロード · 再開可能 · \(localizedFragment(String(en.dropFirst("Not downloaded · resumable · ".count))))"
        }
        if en.hasPrefix("Not downloaded · About "), en.hasSuffix(" MB") {
            let amount = en
                .replacingOccurrences(of: "Not downloaded · About ", with: "")
                .replacingOccurrences(of: " MB", with: "")
            return "未ダウンロード · 約 \(amount) MB"
        }
        if en.hasPrefix("Not downloaded · ") {
            return "未ダウンロード · \(localizedFragment(String(en.dropFirst("Not downloaded · ".count))))"
        }
        if en.hasPrefix("Not installed (~"), en.hasSuffix("MB)") {
            let amount = en
                .replacingOccurrences(of: "Not installed (~", with: "")
                .replacingOccurrences(of: "MB)", with: "")
            return "未インストール (~\(amount)MB)"
        }
        if en.hasPrefix("Files ") {
            return "ファイル \(String(en.dropFirst("Files ".count)))"
        }
        if let range = en.range(of: " complete, "), en.hasSuffix(" can resume.") {
            let completed = String(en[..<range.lowerBound])
            let resumable = String(en[range.upperBound...].dropLast(" can resume.".count))
            return "\(completed)完了、\(resumable)件を再開できます。"
        }
        if let range = en.range(of: " complete. "), en.hasSuffix("You can resume downloading.") {
            let completed = String(en[..<range.lowerBound])
            return "\(completed)完了。ダウンロードを再開できます。"
        }
        if let range = en.range(of: " · ") {
            let prefix = String(en[..<range.lowerBound])
            let suffix = String(en[range.upperBound...])
            let localizedPrefix = localizedFragment(prefix)
            if localizedPrefix != prefix {
                return "\(localizedPrefix) · \(suffix)"
            }
        }
        if en.hasSuffix(" enabled"), let n = en.split(separator: " ").first {
            return "\(n)件が有効"
        }
        if en.hasSuffix(" skills total"), let n = en.split(separator: " ").first {
            return "合計\(n)件のスキル"
        }
        if en.hasSuffix(" lines"), let n = en.split(separator: " ").first {
            return "\(n)行"
        }
        if en.hasPrefix("Used ") {
            return "\(String(en.dropFirst("Used ".count)))を使用しました"
        }
        if en.hasPrefix("Using "), en.hasSuffix("…") {
            let name = String(en.dropFirst("Using ".count).dropLast())
            return "\(name)を使用中…"
        }
        if en.hasPrefix("[Attachment: "), en.hasSuffix(" — audio decode failed]") {
            let name = en
                .replacingOccurrences(of: "[Attachment: ", with: "")
                .replacingOccurrences(of: " — audio decode failed]", with: "")
            return "[添付: \(name) — 音声のデコードに失敗]"
        }
        if en.hasPrefix("[Attachment: "), en.hasSuffix(" — couldn't extract text from PDF]") {
            let name = en
                .replacingOccurrences(of: "[Attachment: ", with: "")
                .replacingOccurrences(of: " — couldn't extract text from PDF]", with: "")
            return "[添付: \(name) — PDFからテキストを抽出できません]"
        }
        if en.hasPrefix("[Attachment: "), en.hasSuffix(" — couldn't open PDF]") {
            let name = en
                .replacingOccurrences(of: "[Attachment: ", with: "")
                .replacingOccurrences(of: " — couldn't open PDF]", with: "")
            return "[添付: \(name) — PDFを開けません]"
        }
        if en.hasPrefix("[Attachment: "), en.hasSuffix("]") {
            let name = en
                .replacingOccurrences(of: "[Attachment: ", with: "")
                .replacingOccurrences(of: "]", with: "")
            return "[添付: \(name)]"
        }
        if en.hasPrefix("Contents of "), let range = en.range(of: ":\n") {
            let name = String(en[en.index(en.startIndex, offsetBy: "Contents of ".count)..<range.lowerBound])
            let content = String(en[range.upperBound...])
            return "\(name)の内容:\n\(content)"
        }
        return nil
    }

    private static func localizedFragment(_ value: String) -> String {
        exact[value] ?? value
    }
}

// MARK: - Global helper

/// 根据当前语言选择文案。`ja` 可选; 不传时日语先走集中 fallback, 再回退英文。
///
/// 注意: 在 SwiftUI View body 里调用会建立 observation 依赖
/// (读了 `LanguageService.shared.current`), 语言切换会自动重渲染。
func tr(_ zh: String, _ en: String, _ ja: String? = nil) -> String {
    switch LanguageService.shared.current.resolved {
    case .zhHans:
        return zh
    case .ja:
        return ja ?? JapaneseFallbackLocalization.text(zh: zh, en: en) ?? en
    default:
        return en
    }
}
