import Foundation

// MARK: - Hotfix Feature Flags
//
// 环境变量/UserDefaults 驱动的功能开关。允许在不改代码的前提下
// 切换 prompt pipeline 策略、工具结果规范化等行为。
// 读取顺序: 环境变量 > UserDefaults > 编译时默认。

private enum HotfixFlagKey: String {
    case useHotfixPromptPipeline = "PHONECLAW_USE_HOTFIX_PROMPT_PIPELINE"
    case enablePreflightBudget = "ENABLE_PREFLIGHT_BUDGET"
    case enableCanonicalToolResult = "ENABLE_CANONICAL_TOOL_RESULT"
    case enableHistoryTrim = "ENABLE_HISTORY_TRIM"
    case enableMultimodalSessionGroup = "ENABLE_MULTIMODAL_SESSION_GROUP"
    case enableImageFollowUpRegrounding = "ENABLE_IMAGE_FOLLOWUP_REGROUNDING"
    case enableGuardedSkillRouter = "ENABLE_GUARDED_SKILL_ROUTER"
    case enableIOS27FoundationRouter = "ENABLE_IOS27_FOUNDATION_ROUTER"
    case enableFoundationModelsInferenceService = "ENABLE_FOUNDATION_MODELS_INFERENCE_SERVICE"
    case enableLiveFoundationTokenSource = "ENABLE_LIVE_FOUNDATION_TOKEN_SOURCE"
}

enum HotfixFeatureFlags {
    static var useHotfixPromptPipeline: Bool {
        value(for: .useHotfixPromptPipeline, defaultValue: true)
    }

    static var enablePreflightBudget: Bool {
        value(for: .enablePreflightBudget, defaultValue: true)
    }

    static var enableCanonicalToolResult: Bool {
        value(for: .enableCanonicalToolResult, defaultValue: true)
    }

    static var enableHistoryTrim: Bool {
        value(for: .enableHistoryTrim, defaultValue: true)
    }

    static var enableMultimodalSessionGroup: Bool {
        value(for: .enableMultimodalSessionGroup, defaultValue: true)
    }

    static var enableImageFollowUpRegrounding: Bool {
        value(for: .enableImageFollowUpRegrounding, defaultValue: true)
    }

    static var enableGuardedSkillRouter: Bool {
        value(for: .enableGuardedSkillRouter, defaultValue: true)
    }

    static var enableIOS27FoundationRouter: Bool {
        value(for: .enableIOS27FoundationRouter, defaultValue: true)
    }

    static var enableFoundationModelsInferenceService: Bool {
        value(for: .enableFoundationModelsInferenceService, defaultValue: false)
    }

    static var enableLiveFoundationTokenSource: Bool {
        value(for: .enableLiveFoundationTokenSource, defaultValue: true)
    }

    private static func value(for key: HotfixFlagKey, defaultValue: Bool) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[key.rawValue] {
            switch raw.lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        if UserDefaults.standard.object(forKey: key.rawValue) != nil {
            return UserDefaults.standard.bool(forKey: key.rawValue)
        }

        return defaultValue
    }
}
