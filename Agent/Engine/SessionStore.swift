import Foundation

// MARK: - SessionStore 内部数据类型

struct ChatSessionRecord: Codable {
    let id: UUID
    var title: String
    var preview: String
    var updatedAt: Date
    var messages: [ChatMessage]
}

extension AgentEngine {

    // MARK: - 保存调度

    func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        let currentID = currentSessionID
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.currentSessionID == currentID else { return }
            self.saveCurrentSession()
        }
    }

    func saveCurrentSession() {
        guard !messages.isEmpty else { return }

        let summary = makeSessionSummary(
            id: currentSessionID,
            messages: messages
        )
        let record = ChatSessionRecord(
            id: currentSessionID,
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
            try data.write(to: sessionFileURL(for: currentSessionID), options: .atomic)
            updateSessionSummary(summary)
            persistSessionsIndex()
            UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
            _ = directory
        } catch {
            log("[History] save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 加载

    func loadPersistedSessions() {
        do {
            _ = try ensureSessionsDirectory()
        } catch {
            log("[History] setup failed: \(error.localizedDescription)")
        }

        sessionSummaries = loadSessionsIndex().sorted { $0.updatedAt > $1.updatedAt }

        if let record = loadSessionRecord(id: currentSessionID) {
            resetPromptPipelineState()
            messages = record.messages
            updateSessionSummary(
                .init(
                    id: record.id,
                    title: record.title,
                    preview: record.preview,
                    updatedAt: record.updatedAt
                )
            )
            return
        }

        if let first = sessionSummaries.first, let record = loadSessionRecord(id: first.id) {
            resetPromptPipelineState()
            currentSessionID = first.id
            UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
            messages = record.messages
            return
        }

        resetPromptPipelineState()
        currentSessionID = UUID()
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = []
    }

    func loadSessionRecord(id: UUID) -> ChatSessionRecord? {
        let url = sessionFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatSessionRecord.self, from: data)
    }

    // MARK: - 摘要

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

    func updateSessionSummary(_ summary: ChatSessionSummary) {
        if let index = sessionSummaries.firstIndex(where: { $0.id == summary.id }) {
            sessionSummaries[index] = summary
        } else {
            sessionSummaries.append(summary)
        }
        sessionSummaries.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 索引文件

    func persistSessionsIndex() {
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

    // MARK: - URL helpers

    func ensureSessionsDirectory() throws -> URL {
        let directory = sessionsDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func sessionsIndexURL() -> URL {
        sessionsDirectoryURL().appendingPathComponent(sessionsIndexFileName)
    }

    func sessionFileURL(for id: UUID) -> URL {
        sessionsDirectoryURL().appendingPathComponent("\(id.uuidString).json")
    }

    func sessionsDirectoryURL() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("PhoneClaw", isDirectory: true)
        return appDir.appendingPathComponent(sessionsDirectoryName, isDirectory: true)
    }
}
