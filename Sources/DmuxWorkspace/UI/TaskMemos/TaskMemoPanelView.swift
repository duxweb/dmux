import SwiftUI

struct TaskMemoPanelView: View {
    let model: AppModel
    @State private var draftText = ""
    @State private var draftStatus: TaskMemoStatus = .waiting
    @State private var isDraftFocused = false

    private var focusedSession: TerminalSession? {
        if let focusedSessionID = model.taskMemoFocusedSessionID,
           let session = model.terminalSession(for: focusedSessionID),
           session.projectID == model.selectedProjectID {
            return session
        }
        return model.selectedSessionID.flatMap { model.terminalSession(for: $0) }
    }

    private var currentProject: Project? {
        focusedSession.flatMap { session in
            model.projects.first(where: { $0.id == session.projectID })
        } ?? model.selectedProject
    }

    private var items: [TaskMemoItem] {
        guard let projectID = currentProject?.id else {
            return []
        }
        return model.taskMemos(for: projectID, sessionID: focusedSession?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GitPanelSeparator()
            composer
            GitPanelSeparator()
            content
        }
        .background(Color.clear)
        .onChange(of: model.selectedProjectID) { _, _ in
            if let focusedSessionID = model.taskMemoFocusedSessionID,
               model.terminalSession(for: focusedSessionID)?.projectID != model.selectedProjectID {
                model.taskMemoFocusedSessionID = model.selectedSessionID
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "task_memo.panel.title", defaultValue: "Task Memos", bundle: .module))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                model.closeTaskMemoPanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GitToolbarIconButtonStyle())
            .help(String(localized: "common.close", defaultValue: "Close", bundle: .module))
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var headerSubtitle: String {
        guard let project = currentProject else {
            return String(localized: "task_memo.no_project", defaultValue: "No Project Selected", bundle: .module)
        }
        return project.name
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppMultilineInputArea(
                text: $draftText,
                placeholder: String(localized: "task_memo.input.placeholder", defaultValue: "Add a task memo...", bundle: .module),
                isFocused: $isDraftFocused,
                font: .systemFont(ofSize: 12, weight: .regular),
                horizontalInset: 8,
                verticalInset: 8,
                enablesSpellChecking: true
            )
            .frame(minHeight: 82, maxHeight: 118)

            HStack(spacing: 8) {
                TaskMemoStatusMenu(selectedStatus: draftStatus) { status in
                    draftStatus = status
                }
                Spacer(minLength: 0)
                Button {
                    addDraft()
                } label: {
                    Label(String(localized: "task_memo.add", defaultValue: "Add", bundle: .module), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(focusedSession == nil || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if currentProject == nil {
            TaskMemoEmptyView(
                symbol: "checklist.unchecked",
                title: String(localized: "task_memo.no_project", defaultValue: "No Project Selected", bundle: .module),
                message: String(localized: "task_memo.no_project.help", defaultValue: "Select a project and terminal session to add task memos.", bundle: .module)
            )
        } else if items.isEmpty {
            TaskMemoEmptyView(
                symbol: "checklist",
                title: String(localized: "task_memo.empty.title", defaultValue: "No Task Memos", bundle: .module),
                message: String(localized: "task_memo.empty.help", defaultValue: "Queued memos are sent one by one after this session finishes an AI turn.", bundle: .module)
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        TaskMemoRow(model: model, item: item)
                    }
                }
                .padding(14)
            }
        }
    }

    private func addDraft() {
        guard let session = focusedSession else {
            return
        }
        if model.addTaskMemo(projectID: session.projectID, sessionID: session.id, content: draftText, status: draftStatus) != nil {
            draftText = ""
            draftStatus = .waiting
        }
    }
}

private struct TaskMemoRow: View {
    let model: AppModel
    let item: TaskMemoItem
    @State private var editText: String = ""
    @State private var isEditorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TaskMemoStatusMenu(selectedStatus: item.status) { status in
                    model.setTaskMemoStatus(item.id, status: status)
                }

                Spacer(minLength: 8)

                Button {
                    _ = model.executeTaskMemoNow(item.id, content: editText)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GitHeaderIconButtonStyle())
                .help(String(localized: "task_memo.execute_now", defaultValue: "Send Now", bundle: .module))
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if item.status == .completed {
                    Button {
                        model.requeueTaskMemo(item.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GitHeaderIconButtonStyle())
                    .help(String(localized: "task_memo.requeue", defaultValue: "Requeue", bundle: .module))
                }

                if hasUnsavedChanges {
                    Button {
                        model.updateTaskMemo(item.id, content: editText)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GitHeaderIconButtonStyle())
                    .help(String(localized: "common.save", defaultValue: "Save", bundle: .module))
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    model.deleteTaskMemo(item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GitHeaderIconButtonStyle())
                .help(String(localized: "common.delete", defaultValue: "Delete", bundle: .module))
            }

            AppMultilineInputArea(
                text: $editText,
                placeholder: String(localized: "task_memo.input.placeholder", defaultValue: "Add a task memo...", bundle: .module),
                isFocused: $isEditorFocused,
                font: .systemFont(ofSize: 12, weight: .regular),
                horizontalInset: 6,
                verticalInset: 6,
                enablesSpellChecking: true
            )
            .frame(minHeight: 62, maxHeight: 128)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.panel.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.status.tint.opacity(0.28), lineWidth: 0.7)
        }
        .onAppear {
            editText = item.content
        }
        .onChange(of: item.content) { _, newValue in
            if editText != newValue {
                editText = newValue
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        editText.trimmingCharacters(in: .whitespacesAndNewlines) != item.content
    }
}

private struct TaskMemoEmptyView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.textMuted)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct TaskMemoStatusMenu: View {
    let selectedStatus: TaskMemoStatus
    let onSelect: (TaskMemoStatus) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            statusTag
        }
        .buttonStyle(.plain)
        .appCursor(.pointingHand)
        .fixedSize()
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(String(localized: "task_memo.change_status", defaultValue: "Change Status", bundle: .module))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(TaskMemoStatus.allCases, id: \.self) { status in
                    Button {
                        onSelect(status)
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: status == selectedStatus ? "checkmark" : status.menuSymbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 14)
                            Text(status.title)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 12)
                        }
                        .foregroundStyle(status == selectedStatus ? status.tint : AppTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(width: 118, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(status == selectedStatus ? status.tint.opacity(0.14) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .appCursor(.pointingHand)
                }
            }
            .padding(6)
            .background(AppTheme.panel)
        }
    }

    private var statusTag: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(selectedStatus.tint)
                .frame(width: 8, height: 8)
            Text(selectedStatus.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selectedStatus.tint)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 68)
        .frame(height: 24)
        .background(selectedStatus.tint.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension TaskMemoStatus {
    var title: String {
        displayTitle
    }

    var tint: Color {
        switch self {
        case .queued:
            return AppTheme.success
        case .waiting:
            return AppTheme.warning
        case .completed:
            return AppTheme.textMuted
        }
    }

    var menuSymbolName: String {
        switch self {
        case .queued:
            return "list.bullet"
        case .waiting:
            return "clock"
        case .completed:
            return "checkmark.circle"
        }
    }
}
