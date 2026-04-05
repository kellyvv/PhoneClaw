import SwiftUI

// MARK: - 显示模型（跨平台共享）

/// 单个 Skill 卡片数据
struct SkillCard: Identifiable, Equatable {
    let id: UUID
    var skillName: String
    var skillStatus: String?   // "identified", "loaded", "executing", "done"
    var toolName: String?      // 正在执行的具体 Tool 名（如 "device-info"）
}

/// AI 回复块：多张 skill 卡片 + 思考动画 + 回复文本
struct ResponseBlock: Identifiable, Equatable {
    let id: UUID
    var skills: [SkillCard] = []
    var responseText: String?
    var isThinking: Bool
}

/// 聊天列表的统一显示项
enum DisplayItem: Identifiable {
    case user(ChatMessage)
    case response(ResponseBlock)

    var id: UUID {
        switch self {
        case .user(let msg): return msg.id
        case .response(let block): return block.id
        }
    }
}

// MARK: - Messages → DisplayItems 转换（跨平台共享）

/// 用于纯思考占位的稳定 ID
private let thinkingPlaceholderID = UUID()

func buildDisplayItems(from messages: [ChatMessage], isProcessing: Bool) -> [DisplayItem] {
    var items: [DisplayItem] = []
    var block: ResponseBlock? = nil

    func flush() {
        if let b = block { items.append(.response(b)); block = nil }
    }

    for msg in messages {
        switch msg.role {
        case .user:
            flush()
            items.append(.user(msg))
        case .system:
            if let name = msg.skillName {
                if block == nil { block = ResponseBlock(id: msg.id, isThinking: false) }

                let content = msg.content
                // 查找已有的同名卡片 → 更新状态；否则新建
                if let idx = block?.skills.firstIndex(where: { $0.skillName == name }) {
                    if content.hasPrefix("executing:") {
                        block?.skills[idx].skillStatus = "executing"
                        block?.skills[idx].toolName = String(content.dropFirst("executing:".count))
                    } else {
                        block?.skills[idx].skillStatus = content
                    }
                } else {
                    var card = SkillCard(id: msg.id, skillName: name)
                    if content.hasPrefix("executing:") {
                        card.skillStatus = "executing"
                        card.toolName = String(content.dropFirst("executing:".count))
                    } else {
                        card.skillStatus = content
                    }
                    block?.skills.append(card)
                }
            }
        case .skillResult:
            break
        case .assistant:
            if block == nil { block = ResponseBlock(id: msg.id, isThinking: false) }
            if msg.content != "▍" && !msg.content.isEmpty {
                block?.responseText = msg.content
            }
        }
    }

    if var b = block, !b.skills.isEmpty || b.responseText != nil {
        if isProcessing && !b.skills.isEmpty && b.responseText == nil {
            b.isThinking = true
        }
        items.append(.response(b))
    }

    if isProcessing {
        let hasAI = block.map { !$0.skills.isEmpty || $0.responseText != nil } ?? false
        if !hasAI {
            items.append(.response(ResponseBlock(id: thinkingPlaceholderID, isThinking: true)))
        }
    }

    return items
}
