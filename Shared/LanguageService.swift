import Foundation
import SwiftUI

// MARK: - PhoneClaw Language Service
//
// 单一语言入口。全 app 不再各自写 `Locale.preferredLanguages.contains { $0.hasPrefix("zh") }`,
// 统一通过 `LanguageService.shared.current.resolved` 拿到生效语言 (zhHans / en)。
//
// 设计约束:
//   - `.auto` 是 default, resolve 时看系统 locale (行为类似微信: 默认跟系统)
//   - 用户可在配置页手动覆盖成 `.zhHans` / `.en`
//   - 切换立即生效, SwiftUI 视图通过 @Observable 自动重渲染
//   - 会话边界: 语言切换只影响下一次新开会话, 当前对话不动 (AgentEngine 读 current 时快照)
//
// 不包含:
//   - Live 英文支持 — ASR/TTS 语音能力另有评估, 英文 Live 阶段性禁用
//   - 运行时切换时清空已生成对话 — 用户可能正在翻阅历史, 不触发破坏性操作

// MARK: - AppLanguage

/// 用户可选的语言偏好。`.auto` 走系统 locale, 其它两个是硬覆盖。
enum AppLanguage: String, CaseIterable, Codable {
    case auto   = "auto"
    case zhHans = "zh-Hans"
    case en     = "en"

    /// 配置页 Picker 的显示名。`.auto` 显示名自身依赖当前语言, 所以用 `tr()`。
    var displayName: String {
        switch self {
        case .auto:   return tr("自动", "Auto")
        case .zhHans: return "中文"
        case .en:     return "English"
        }
    }
}

// MARK: - LocalizationContext

/// 一次生效的语言解析结果。`raw` 保留用户的选择 (含 `.auto`);
/// `resolved` 永远是 `.zhHans` 或 `.en`, 不会是 `.auto` — UI 和 prompt 用这个。
struct LocalizationContext: Equatable {
    let raw: AppLanguage
    let resolved: AppLanguage

    var isChinese: Bool { resolved == .zhHans }
    var isEnglish: Bool { resolved == .en }
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

    /// 根据 raw 选择计算 resolved 语言。`.auto` 走系统 preferred languages,
    /// 只要第一条以 `zh` 开头就判为中文, 其它一律英文 (不做第三语言降级)。
    private static func resolve(raw: AppLanguage) -> LocalizationContext {
        let resolved: AppLanguage
        switch raw {
        case .auto:
            // 只看首选语言, 不用 `contains`: 用户主语言英文但备用语言有中文时, 应保持英文。
            // `lowercased()`: iOS 通常返回小写 ("zh-hans"), 但不同平台/模拟器配置可能
            // 返回大小写混合, 先归一化避免边界踩坑。
            let isZh = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
            resolved = isZh ? .zhHans : .en
        case .zhHans, .en:
            resolved = raw
        }
        return LocalizationContext(raw: raw, resolved: resolved)
    }
}

// MARK: - Global helper

/// 两字符串中根据当前语言选一个。等价于
/// `LanguageService.shared.current.isChinese ? zh : en`,
/// 但更短, 方便大量 inline 使用。
///
/// 注意: 在 SwiftUI View body 里调用会建立 observation 依赖
/// (读了 `LanguageService.shared.current`), 语言切换会自动重渲染。
func tr(_ zh: String, _ en: String) -> String {
    LanguageService.shared.current.isChinese ? zh : en
}
