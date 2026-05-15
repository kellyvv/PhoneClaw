import Foundation

// MARK: - PhoneClaw L10n String Namespace
//
// 所有 UI 文案都走这个 typed namespace, 不再在 View 里散写 `tr("中文", "English")`。
//
// 结构:
//   L10n.<UI 域>.<具体 key>
//
// 每个 key 是 `static var`, 内部调 `tr(zh, en)`, 运行时按当前语言取值。
// 新增文案: 找对应子 enum 加一行。找不到合适域就新增子 enum。
//
// 不要存成 `static let` (会在类型初始化时 snapshot 语言, 切换语言不刷新)。
// 必须是 `static var` 每次访问时重新调用 `tr()`。
//
// MARK: - 覆盖度迁移说明
//
// Phase 1 先只定义本次用到的 key (配置页"语言"选项 + 部分复用 key),
// 随后每个 Phase 按需新增。最终目标: 全 app 硬编码字面量 == 0。

enum L10n {

    // MARK: - 配置页 (Configurations)

    enum Config {
        static var title:             String { tr("配置", "Configuration") }
        static var modelSettings:     String { tr("模型设置", "Model") }
        static var systemPrompt:      String { tr("系统提示词", "System Prompt") }
        static var permissions:       String { tr("权限", "Permissions") }

        static var cancel:            String { tr("取消", "Cancel") }
        static var confirm:           String { tr("确定", "OK") }

        static var language:          String { tr("语言", "Language") }
        static var languageFooter:    String {
            // 短语刻意控长度跟中文版接近 — 之前的英文版换行成 2 行,
            // 中英切换时整个 layout 跳一截 (Configurations sheet 高度变化).
            tr(
                "界面会立即更新，新对话使用新的语言偏好。",
                "Interface updates immediately. New chats use the new language."
            )
        }
    }

    // MARK: - Chat / Agent (待 Phase 2 填充)

    enum Chat {
        // 占位, Phase 2 开始填充
    }

    // MARK: - Skills (待 Phase 3 填充)

    enum Skills {
        // 占位, Phase 3 开始填充
    }

    // MARK: - Live 语音模式

    enum Live {
        static var voiceModelsRequired: String {
            tr(
                "请先下载当前语言的语音模型。",
                "Download the voice models for the current language first."
            )
        }
    }

    // MARK: - 错误 / 状态消息 (待 Phase 2/4 填充)

    enum Error {
        // 占位
    }
}
