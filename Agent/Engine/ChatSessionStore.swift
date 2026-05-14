import Foundation

// MARK: - ChatSessionRecord

struct ChatSessionRecord: Codable {
    let id: UUID
    var title: String
    var preview: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

// MARK: - ChatSessionStore
//
// 会话持久化层。从 AgentEngine 抽取出来的纯数据/IO 模块。
//
// 职责:
//   - 会话文件的 save / load / delete / index
//   - 会话摘要 (title + preview) 生成
//   - 保存调度 (debounce 350ms)
//   - currentSessionID / sessionSummaries 管理
//
// 不做:
//   - 推理生命周期管理 (那是 Coordinator 的事)
//   - 消息内容管理 (messages 仍在 AgentEngine)
//   - KV cache / inference reset (那是 AgentEngine 的编排逻辑)
//
// 与 AgentEngine 的关系:
//   AgentEngine 持有 ChatSessionStore，在 startNewSession / loadSession /
//   deleteSession 等编排方法中调用 store 的 API 完成纯数据操作。
//   AgentEngine 自己负责 cancel / resetKV / resetPromptPipeline 等运行时清理。

@Observable
@MainActor
final class ChatSessionStore {

    // MARK: - Observed State

    /// 当前活跃会话 ID
    var currentSessionID: UUID

    /// 所有会话摘要 (UI 列表数据源)
    var sessionSummaries: [ChatSessionSummary] = []

    // MARK: - Private

    private var sessionSaveTask: Task<Void, Never>?
    private let sessionsDirectoryName = "Sessions"
    private let sessionsIndexFileName = "sessions_index.json"
    static let currentSessionDefaultsKey = "PhoneClaw.currentSessionID"

    // MARK: - Init

    init() {
        self.currentSessionID =
            UUID(uuidString: UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey) ?? "")
            ?? UUID()
    }

    // MARK: - Save Scheduling

    /// 延迟保存 (debounce 350ms)。调用方在 messages.didSet 中触发。
    func scheduleSave(messages: [ChatMessage]) {
        sessionSaveTask?.cancel()
        let currentID = currentSessionID
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.currentSessionID == currentID else { return }
            self.saveSession(id: currentID, messages: messages)
        }
    }

    /// 立即保存当前会话 (取消任何 pending debounce)。
    func flushPendingSave(messages: [ChatMessage]) {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        saveSession(id: currentSessionID, messages: messages)
    }

    /// 取消 pending save (不执行保存)。
    func cancelPendingSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
    }

    // MARK: - Save

    func saveSession(id: UUID, messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }

        let summary = makeSessionSummary(id: id, messages: messages)
        let record = ChatSessionRecord(
            id: id,
            title: summary.title,
            preview: summary.preview,
            updatedAt: summary.updatedAt,
            messages: messages
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let directory = try ensureSessionsDirectory()
            let data = try encoder.encode(record)
            try data.write(to: sessionFileURL(for: id), options: .atomic)
            updateSessionSummary(summary)
            persistSessionsIndex()
            UserDefaults.standard.set(id.uuidString, forKey: Self.currentSessionDefaultsKey)
            _ = directory
        } catch {
            log("[History] save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    /// 启动时加载持久化的会话数据。返回待恢复的消息 (如果有)。
    func loadPersistedSessions() -> [ChatMessage] {
        do {
            _ = try ensureSessionsDirectory()
        } catch {
            log("[History] setup failed: \(error.localizedDescription)")
        }

        sessionSummaries = loadSessionsIndex().sorted { $0.updatedAt > $1.updatedAt }

        // 尝试恢复当前 session
        if let record = loadSessionRecord(id: currentSessionID) {
            updateSessionSummary(
                .init(
                    id: record.id,
                    title: record.title,
                    preview: record.preview,
                    updatedAt: record.updatedAt
                )
            )
            return record.messages
        }

        // 尝试恢复最近的 session
        if let first = sessionSummaries.first, let record = loadSessionRecord(id: first.id) {
            currentSessionID = first.id
            UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
            return record.messages
        }

        // 全新状态
        currentSessionID = UUID()
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        return []
    }

    func loadSessionRecord(id: UUID) -> ChatSessionRecord? {
        let url = sessionFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatSessionRecord.self, from: data)
    }

    // MARK: - New Session

    /// 创建新会话。返回新的 session ID。
    func newSession() -> UUID {
        let newID = UUID()
        currentSessionID = newID
        UserDefaults.standard.set(newID.uuidString, forKey: Self.currentSessionDefaultsKey)
        return newID
    }

    // MARK: - Load Session

    /// 切换到指定会话。返回消息列表 (nil = session 不存在)。
    func switchToSession(id: UUID) -> [ChatMessage]? {
        guard let record = loadSessionRecord(id: id) else { return nil }
        currentSessionID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.currentSessionDefaultsKey)
        updateSessionSummary(
            .init(
                id: record.id,
                title: record.title,
                preview: record.preview,
                updatedAt: record.updatedAt
            )
        )
        return record.messages
    }

    // MARK: - Delete Session

    /// 删除指定会话。
    ///
    /// 返回值:
    ///   - `nil`: 删除的不是当前会话，无需切换
    ///   - `[]`:  删除的是当前会话且无其他会话，应显示空状态
    ///   - `[msg…]`: 删除的是当前会话，已切换到下一个会话
    func deleteSession(id: UUID) -> [ChatMessage]? {
        // Delete file
        do {
            try FileManager.default.removeItem(at: sessionFileURL(for: id))
        } catch {
            log("[History] delete failed: \(error.localizedDescription)")
        }
        sessionSummaries.removeAll { $0.id == id }
        persistSessionsIndex()

        // If deleted the current session, need to switch
        guard id == currentSessionID else { return nil }

        cancelPendingSave()

        if let next = sessionSummaries.first, let record = loadSessionRecord(id: next.id) {
            currentSessionID = next.id
            UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
            return record.messages
        } else {
            currentSessionID = UUID()
            UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
            return []
        }
    }

    // MARK: - Summary Generation

    func makeSessionSummary(id: UUID, messages: [ChatMessage]) -> ChatSessionSummary {
        let firstUser = messages.first(where: { $0.role == .user })
        let lastMeaningful = messages.reversed().first(where: { msg in
            if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return !msg.images.isEmpty || !msg.audios.isEmpty
        })

        let title = sessionTitle(from: firstUser)
        let preview = sessionPreview(from: lastMeaningful ?? firstUser)
        let updatedAt = (lastMeaningful ?? firstUser)?.timestamp ?? Date()

        return ChatSessionSummary(
            id: id,
            title: title,
            preview: preview,
            updatedAt: updatedAt
        )
    }

    func updateSessionSummary(_ summary: ChatSessionSummary) {
        if let index = sessionSummaries.firstIndex(where: { $0.id == summary.id }) {
            sessionSummaries[index] = summary
        } else {
            sessionSummaries.append(summary)
        }
        sessionSummaries.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Private Helpers

    private func sessionTitle(from message: ChatMessage?) -> String {
        guard let message else { return tr("新会话", "New Chat") }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(24))
        }
        if !message.images.isEmpty && !message.audios.isEmpty {
            return tr("图片与语音会话", "Image & Voice Chat")
        }
        if !message.images.isEmpty {
            return tr("图片会话", "Image Chat")
        }
        if !message.audios.isEmpty {
            return tr("语音会话", "Voice Chat")
        }
        return tr("新会话", "New Chat")
    }

    private func sessionPreview(from message: ChatMessage?) -> String {
        guard let message else { return tr("暂无内容", "No content") }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(80))
        }
        if !message.images.isEmpty && !message.audios.isEmpty {
            return tr("包含图片与语音", "Contains images and voice")
        }
        if !message.images.isEmpty {
            return tr("包含图片", "Contains images")
        }
        if !message.audios.isEmpty {
            return tr("包含语音", "Contains voice")
        }
        return tr("暂无内容", "No content")
    }

    // MARK: - Index File

    private func persistSessionsIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(sessionSummaries)
            try data.write(to: sessionsIndexURL(), options: .atomic)
        } catch {
            log("[History] index save failed: \(error.localizedDescription)")
        }
    }

    private func loadSessionsIndex() -> [ChatSessionSummary] {
        let url = sessionsIndexURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatSessionSummary].self, from: data)) ?? []
    }

    // MARK: - URL Helpers

    private func ensureSessionsDirectory() throws -> URL {
        let directory = sessionsDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sessionsIndexURL() -> URL {
        sessionsDirectoryURL().appendingPathComponent(sessionsIndexFileName)
    }

    func sessionFileURL(for id: UUID) -> URL {
        sessionsDirectoryURL().appendingPathComponent("\(id.uuidString).json")
    }

    private func sessionsDirectoryURL() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("PhoneClaw", isDirectory: true)
        return appDir.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    }
}
