import AppKit
import Foundation

extension AppModel {
    func openTaskMemoPanel(for sessionID: UUID) {
        guard let session = terminalSession(for: sessionID) else {
            statusMessage = String(localized: "task_memo.session_missing", defaultValue: "Unable to find this terminal session.", bundle: .module)
            return
        }

        taskMemoFocusedSessionID = session.id
        updateSelectedProjectID(session.projectID, source: "openTaskMemoPanel")
        rightPanel = .taskMemos
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
    }

    func closeTaskMemoPanel() {
        if rightPanel == .taskMemos {
            rightPanel = nil
        }
    }

    func taskMemos(for projectID: UUID, sessionID: UUID?) -> [TaskMemoItem] {
        taskMemos
            .filter { item in
                item.projectID == projectID && (sessionID == nil || item.sessionID == sessionID)
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status.sortPriority < rhs.status.sortPriority
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func taskMemoCounts(projectID: UUID, sessionID: UUID?) -> (queued: Int, waiting: Int, completed: Int) {
        let items = taskMemos(for: projectID, sessionID: sessionID)
        return (
            queued: items.filter { $0.status == .queued }.count,
            waiting: items.filter { $0.status == .waiting }.count,
            completed: items.filter { $0.status == .completed }.count
        )
    }

    @discardableResult
    func addTaskMemo(projectID: UUID, sessionID: UUID, content: String, status: TaskMemoStatus = .queued) -> TaskMemoItem? {
        guard terminalSession(for: sessionID)?.projectID == projectID else {
            statusMessage = String(localized: "task_memo.session_missing", defaultValue: "Unable to find this terminal session.", bundle: .module)
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = String(localized: "task_memo.empty", defaultValue: "Task memo cannot be empty.", bundle: .module)
            return nil
        }

        let now = Date()
        let item = TaskMemoItem(
            id: UUID(),
            projectID: projectID,
            sessionID: sessionID,
            content: trimmed,
            status: status,
            createdAt: now,
            updatedAt: now,
            lastSentAt: nil
        )
        taskMemos.append(item)
        persist()
        statusMessage = String(
            format: String(localized: "task_memo.added_status_format", defaultValue: "Added task memo as %@.", bundle: .module),
            status.displayTitle
        )
        return item
    }

    func updateTaskMemo(_ id: UUID, content: String) {
        guard let index = taskMemos.firstIndex(where: { $0.id == id }) else {
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteTaskMemo(id)
            return
        }

        taskMemos[index].content = trimmed
        taskMemos[index].updatedAt = Date()
        persist()
    }

    func setTaskMemoStatus(_ id: UUID, status: TaskMemoStatus) {
        guard let index = taskMemos.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard taskMemos[index].status != status else {
            return
        }
        taskMemos[index].status = status
        if status == .queued {
            taskMemos[index].lastSentAt = nil
        }
        taskMemos[index].updatedAt = Date()
        persist()
    }

    func requeueTaskMemo(_ id: UUID) {
        setTaskMemoStatus(id, status: .queued)
    }

    @discardableResult
    func executeTaskMemoNow(_ id: UUID, content: String? = nil) -> Bool {
        guard let index = taskMemos.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let trimmed = (content ?? taskMemos[index].content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = String(localized: "task_memo.empty", defaultValue: "Task memo cannot be empty.", bundle: .module)
            return false
        }

        let sessionID = taskMemos[index].sessionID
        let didSend = DmuxTerminalBackend.shared.registry.sendText(trimmed + "\r", to: sessionID)
        debugLog.log(
            "task-memo",
            "execute-now project=\(taskMemos[index].projectID.uuidString) session=\(sessionID.uuidString) memo=\(id.uuidString) success=\(didSend)"
        )
        guard didSend else {
            statusMessage = String(localized: "task_memo.execute_failed", defaultValue: "Unable to send this task memo.", bundle: .module)
            return false
        }

        let now = Date()
        taskMemos[index].content = trimmed
        taskMemos[index].status = .waiting
        taskMemos[index].lastSentAt = now
        taskMemos[index].updatedAt = now
        persist()
        statusMessage = String(localized: "task_memo.executed", defaultValue: "Sent task memo.", bundle: .module)
        return true
    }

    func deleteTaskMemo(_ id: UUID) {
        let previousCount = taskMemos.count
        taskMemos.removeAll { $0.id == id }
        guard taskMemos.count != previousCount else {
            return
        }
        persist()
    }

    func removeTaskMemos(forSessionID sessionID: UUID) {
        let previousCount = taskMemos.count
        taskMemos.removeAll { $0.sessionID == sessionID }
        if taskMemoFocusedSessionID == sessionID {
            taskMemoFocusedSessionID = selectedSessionID
        }
        guard taskMemos.count != previousCount else {
            return
        }
        persist()
    }

    func sendNextQueuedTaskMemoAfterCompletion(projectID: UUID, completionToken: String) {
        guard let sessionID = aiSessionStore.completedTerminalID(projectID: projectID) else {
            return
        }

        markWaitingTaskMemosCompleted(projectID: projectID, sessionID: sessionID)

        guard let next = nextQueuedTaskMemo(projectID: projectID, sessionID: sessionID) else {
            return
        }

        let didSend = DmuxTerminalBackend.shared.registry.sendText(next.content + "\r", to: sessionID)
        debugLog.log(
            "task-memo",
            "auto-send project=\(projectID.uuidString) session=\(sessionID.uuidString) memo=\(next.id.uuidString) token=\(completionToken) success=\(didSend)"
        )
        guard didSend,
              let index = taskMemos.firstIndex(where: { $0.id == next.id }) else {
            return
        }

        let now = Date()
        taskMemos[index].status = .waiting
        taskMemos[index].lastSentAt = now
        taskMemos[index].updatedAt = now
        persist()
        statusMessage = String(localized: "task_memo.auto_sent", defaultValue: "Sent the next queued task memo.", bundle: .module)
    }

    private func nextQueuedTaskMemo(projectID: UUID, sessionID: UUID) -> TaskMemoItem? {
        taskMemos
            .filter { item in
                item.projectID == projectID
                    && item.sessionID == sessionID
                    && item.status == .queued
            }
            .sorted { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
            .first
    }

    private func markWaitingTaskMemosCompleted(projectID: UUID, sessionID: UUID) {
        var didChange = false
        let now = Date()
        for index in taskMemos.indices where taskMemos[index].projectID == projectID && taskMemos[index].sessionID == sessionID && taskMemos[index].status == .waiting {
            taskMemos[index].status = .completed
            taskMemos[index].updatedAt = now
            didChange = true
        }
        if didChange {
            persist()
        }
    }
}

extension TaskMemoStatus {
    var sortPriority: Int {
        switch self {
        case .queued:
            return 0
        case .waiting:
            return 1
        case .completed:
            return 2
        }
    }

    var displayTitle: String {
        switch self {
        case .queued:
            return String(localized: "task_memo.status.queued", defaultValue: "Queued", bundle: .module)
        case .waiting:
            return String(localized: "task_memo.status.waiting", defaultValue: "Waiting", bundle: .module)
        case .completed:
            return String(localized: "task_memo.status.completed", defaultValue: "Completed", bundle: .module)
        }
    }
}
