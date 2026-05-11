import AppKit
import Foundation

private enum WorkspaceFileCloseDecision {
    case save
    case discard
    case cancel
}

extension AppModel {
    typealias ResolvedWorkspaceContentStates = (
        fileTabs: [UUID: [WorkspaceFileTab]],
        selections: [UUID: WorkspaceContentSelection],
        primaryModes: [UUID: WorkspacePrimaryViewMode]
    )

    static func resolvedWorkspaceContentStates(
        _ states: [WorkspaceContentState]?,
        worktrees: [ProjectWorktree]
    ) -> ResolvedWorkspaceContentStates {
        let validWorktreeIDs = Set(worktrees.map(\.id))
        var fileTabsByWorktreeID: [UUID: [WorkspaceFileTab]] = [:]
        var selectedContentByWorktreeID: [UUID: WorkspaceContentSelection] = [:]
        var primaryModeByWorktreeID: [UUID: WorkspacePrimaryViewMode] = [:]

        for state in states ?? [] where validWorktreeIDs.contains(state.worktreeID) {
            let tabs = uniqueWorkspaceFileTabs(state.fileTabs)
            fileTabsByWorktreeID[state.worktreeID] = tabs
            primaryModeByWorktreeID[state.worktreeID] = state.primaryViewMode == .review ? .terminal : state.primaryViewMode
            if let selectedFileTabID = state.selectedFileTabID,
               tabs.contains(where: { $0.id == selectedFileTabID }) {
                selectedContentByWorktreeID[state.worktreeID] = .file(selectedFileTabID)
            }
        }

        return (
            fileTabs: fileTabsByWorktreeID,
            selections: selectedContentByWorktreeID,
            primaryModes: primaryModeByWorktreeID
        )
    }

    func workspaceContentStatesSnapshot() -> [WorkspaceContentState]? {
        let orderedWorktreeIDs = worktrees.map(\.id)
        var states: [WorkspaceContentState] = []

        for worktreeID in orderedWorktreeIDs {
            let tabs = workspaceFileTabsByWorktreeID[worktreeID] ?? []
            let primaryMode = persistableWorkspacePrimaryViewMode(for: worktreeID)
            let selectedFileTabID: String?
            if case .file(let tabID) = selectedWorkspaceContentByWorktreeID[worktreeID],
               tabs.contains(where: { $0.id == tabID }) {
                selectedFileTabID = tabID
            } else {
                selectedFileTabID = nil
            }

            guard primaryMode != .terminal || !tabs.isEmpty || selectedFileTabID != nil else {
                continue
            }

            states.append(
                WorkspaceContentState(
                    worktreeID: worktreeID,
                    primaryViewMode: primaryMode,
                    selectedFileTabID: selectedFileTabID,
                    fileTabs: tabs
                )
            )
        }

        return states.isEmpty ? nil : states
    }

    func workspacePrimaryViewMode(for worktreeID: UUID) -> WorkspacePrimaryViewMode {
        workspacePrimaryViewModeByWorktreeID[worktreeID] ?? .terminal
    }

    func persistableWorkspacePrimaryViewMode(for worktreeID: UUID) -> WorkspacePrimaryViewMode {
        let primaryMode = workspacePrimaryViewModeByWorktreeID[worktreeID] ?? .terminal
        return primaryMode == .review ? .terminal : primaryMode
    }

    func isSelectedWorkspaceFilesModeActive() -> Bool {
        guard let selectedWorktreeID else {
            return false
        }
        return workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files
    }

    func isSelectedWorkspaceReviewModeActive() -> Bool {
        guard let selectedWorktreeID else {
            return false
        }
        return workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .review
    }

    func isWorkspaceFileCommandActive() -> Bool {
        workspaceFileCommandTarget() != nil
    }

    func workspaceContentSelection(for worktreeID: UUID) -> WorkspaceContentSelection {
        let tabs = workspaceFileTabsByWorktreeID[worktreeID] ?? []
        let selection = selectedWorkspaceContentByWorktreeID[worktreeID] ?? .terminal
        switch selection {
        case .terminal:
            return .terminal
        case .file(let tabID):
            return tabs.contains(where: { $0.id == tabID }) ? selection : .terminal
        }
    }

    func selectWorkspaceTerminal() {
        guard let selectedWorktreeID else {
            return
        }
        workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] = .terminal
        FileBrowserKeyboardFocusState.activateTerminal()
        restoreSelectedTerminalFocusIfNeeded()
        persist()
    }

    func selectWorkspaceFiles() {
        guard let selectedWorktreeID else {
            return
        }
        workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] = .files
        let tabs = workspaceFileTabsByWorktreeID[selectedWorktreeID] ?? []
        if case .file(let tabID) = selectedWorkspaceContentByWorktreeID[selectedWorktreeID],
           tabs.contains(where: { $0.id == tabID }) {
            FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tabID)
            persist()
            return
        }
        if let tab = tabs.last {
            selectedWorkspaceContentByWorktreeID[selectedWorktreeID] = .file(tab.id)
            FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tab.id)
        } else {
            FileBrowserKeyboardFocusState.clearWorkspaceFileEditor(tabID: nil)
        }
        persist()
    }

    func selectWorkspaceReview() {
        guard let selectedWorktreeID else {
            return
        }
        let shouldResetReviewFile = selectedWorktreeReviewID != selectedWorktreeID
        workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] = .review
        selectedWorktreeReviewID = selectedWorktreeID
        if shouldResetReviewFile {
            selectedWorktreeReviewFileID = nil
        }
        FileBrowserKeyboardFocusState.clearWorkspaceFileEditor(tabID: nil)
        DmuxTerminalBackend.shared.registry.clearFocusedSession()
        refreshWorktreeReview()
        persist()
    }

    func selectWorkspaceFileTab(_ tabID: String) {
        guard let selectedWorktreeID else {
            return
        }
        workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] = .files
        selectedWorkspaceContentByWorktreeID[selectedWorktreeID] = .file(tabID)
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tabID)
        persist()
    }

    func workspaceFileTabs(for worktreeID: UUID) -> [WorkspaceFileTab] {
        workspaceFileTabsByWorktreeID[worktreeID] ?? []
    }

    func selectedWorkspaceFileTab(for worktreeID: UUID) -> WorkspaceFileTab? {
        guard case .file(let tabID) = workspaceContentSelection(for: worktreeID) else {
            return nil
        }
        return workspaceFileTabsByWorktreeID[worktreeID]?.first { $0.id == tabID }
    }

    func openFileInWorkspace(_ fileURL: URL, rootURL: URL? = nil) {
        guard let selectedWorktreeID else {
            return
        }
        let standardizedFileURL = fileURL.standardizedFileURL
        let standardizedRootURL = (rootURL ?? selectedProject.map { URL(fileURLWithPath: $0.path, isDirectory: true) } ?? standardizedFileURL.deletingLastPathComponent()).standardizedFileURL
        let tab = WorkspaceFileTab(
            fileURL: standardizedFileURL,
            rootURL: standardizedRootURL,
            title: standardizedFileURL.lastPathComponent
        )

        var tabs = workspaceFileTabsByWorktreeID[selectedWorktreeID] ?? []
        if tabs.contains(where: { $0.id == tab.id }) == false {
            tabs.append(tab)
        }
        workspaceFileTabsByWorktreeID[selectedWorktreeID] = tabs
        workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] = .files
        selectedWorkspaceContentByWorktreeID[selectedWorktreeID] = .file(tab.id)
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tab.id)
        persist()
    }

    @discardableResult
    func closeWorkspaceFileTab(_ tab: WorkspaceFileTab) -> Bool {
        let tabID = tab.id
        if dirtyWorkspaceFileTabIDs.contains(tabID) {
            switch confirmWorkspaceFileCloseDecision() {
            case .save:
                requestSaveAndCloseWorkspaceFileTab(tab)
                return false
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        return closeWorkspaceFileTabWithoutConfirmation(tab)
    }

    @discardableResult
    func closeWorkspaceFileTabAfterSaving(tabID: String) -> Bool {
        guard let (_, tab) = workspaceFileTabMatch(tabID: tabID) else {
            return false
        }
        dirtyWorkspaceFileTabIDs.remove(tabID)
        return closeWorkspaceFileTabWithoutConfirmation(tab)
    }

    private func closeWorkspaceFileTabWithoutConfirmation(_ tab: WorkspaceFileTab) -> Bool {
        let tabID = tab.id
        dirtyWorkspaceFileTabIDs.remove(tabID)
        workspaceFileEditorSaveRequestTokensByTabID.removeValue(forKey: tabID)
        workspaceFileEditorSaveAndCloseRequestTokensByTabID.removeValue(forKey: tabID)
        for worktreeID in Array(workspaceFileTabsByWorktreeID.keys) {
            var tabs = workspaceFileTabsByWorktreeID[worktreeID] ?? []
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
                continue
            }
            tabs.remove(at: index)
            workspaceFileTabsByWorktreeID[worktreeID] = tabs
            if case .file(let selectedTabID) = selectedWorkspaceContentByWorktreeID[worktreeID],
               selectedTabID == tabID {
                if let replacement = tabs[safe: min(index, max(tabs.count - 1, 0))] {
                    selectedWorkspaceContentByWorktreeID[worktreeID] = .file(replacement.id)
                } else {
                    selectedWorkspaceContentByWorktreeID[worktreeID] = .terminal
                }
            }
        }
        if let selectedWorktreeID,
           workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files,
           let selectedTab = selectedWorkspaceFileTab(for: selectedWorktreeID) {
            FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: selectedTab.id)
        } else {
            FileBrowserKeyboardFocusState.clearWorkspaceFileEditor(tabID: tabID)
        }
        persist()
        return true
    }

    func canCloseSelectedWorkspaceFileTab() -> Bool {
        guard let selectedWorktreeID,
              workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files else {
            return false
        }
        return selectedWorkspaceFileTab(for: selectedWorktreeID) != nil
    }

    func canCloseWorkspaceFileCommandTab() -> Bool {
        workspaceFileCommandTarget() != nil
    }

    @discardableResult
    func closeSelectedWorkspaceFileTab() -> Bool {
        guard let selectedWorktreeID,
              workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files,
              let tab = selectedWorkspaceFileTab(for: selectedWorktreeID) else {
            return false
        }
        return closeWorkspaceFileTab(tab)
    }

    @discardableResult
    func closeWorkspaceFileCommandTab() -> Bool {
        guard let (_, tab) = workspaceFileCommandTarget() else {
            AppDebugLog.shared.log(
                "keyboard-routing",
                "close-file-tab skipped reason=no-target selectedWorktree=\(selectedWorktreeID?.uuidString ?? "nil") filesMode=\(isSelectedWorkspaceFilesModeActive()) activeTab=\(FileBrowserKeyboardFocusState.activeWorkspaceFileEditorTabID ?? "nil")"
            )
            return false
        }
        return closeWorkspaceFileTab(tab)
    }

    func canSaveSelectedWorkspaceFileTab() -> Bool {
        guard let selectedWorktreeID,
              workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files else {
            return false
        }
        return selectedWorkspaceFileTab(for: selectedWorktreeID) != nil
    }

    func canSaveWorkspaceFileCommandTab() -> Bool {
        workspaceFileCommandTarget() != nil
    }

    @discardableResult
    func requestSaveSelectedWorkspaceFileTab() -> Bool {
        guard let selectedWorktreeID,
              workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files,
              let tab = selectedWorkspaceFileTab(for: selectedWorktreeID) else {
            return false
        }
        workspaceFileEditorSaveRequestTokensByTabID[tab.id, default: 0] &+= 1
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tab.id)
        return true
    }

    @discardableResult
    func requestSaveWorkspaceFileCommandTab() -> Bool {
        guard let (_, tab) = workspaceFileCommandTarget() else {
            AppDebugLog.shared.log(
                "keyboard-routing",
                "save-file-tab skipped reason=no-target selectedWorktree=\(selectedWorktreeID?.uuidString ?? "nil") filesMode=\(isSelectedWorkspaceFilesModeActive()) activeTab=\(FileBrowserKeyboardFocusState.activeWorkspaceFileEditorTabID ?? "nil")"
            )
            return false
        }
        workspaceFileEditorSaveRequestTokensByTabID[tab.id, default: 0] &+= 1
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tab.id)
        return true
    }

    func workspaceFileEditorSaveRequestToken(for tabID: String) -> Int {
        workspaceFileEditorSaveRequestTokensByTabID[tabID] ?? 0
    }

    func workspaceFileEditorSaveAndCloseRequestToken(for tabID: String) -> Int {
        workspaceFileEditorSaveAndCloseRequestTokensByTabID[tabID] ?? 0
    }

    func setWorkspaceFileTabDirty(_ tabID: String, isDirty: Bool) {
        if isDirty {
            dirtyWorkspaceFileTabIDs.insert(tabID)
        } else {
            dirtyWorkspaceFileTabIDs.remove(tabID)
        }
    }

    func isWorkspaceFileTabDirty(_ tabID: String) -> Bool {
        dirtyWorkspaceFileTabIDs.contains(tabID)
    }

    func openGitEntryInWorkspace(_ entry: GitFileEntry) {
        guard let project = selectedProject else {
            return
        }
        let fileURL = URL(fileURLWithPath: project.path, isDirectory: true).appendingPathComponent(entry.path)
        openFileInWorkspace(fileURL, rootURL: URL(fileURLWithPath: project.path, isDirectory: true))
    }

    private func requestSaveAndCloseWorkspaceFileTab(_ tab: WorkspaceFileTab) {
        guard let target = workspaceFileTabMatch(tabID: tab.id) else {
            return
        }
        workspacePrimaryViewModeByWorktreeID[target.worktreeID] = .files
        selectedWorkspaceContentByWorktreeID[target.worktreeID] = .file(tab.id)
        if selectedWorktreeID == target.worktreeID {
            FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: tab.id)
        }
        workspaceFileEditorSaveAndCloseRequestTokensByTabID[tab.id, default: 0] &+= 1
        persist()
    }

    private func confirmWorkspaceFileCloseDecision() -> WorkspaceFileCloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "files.preview.close_unsaved.title", defaultValue: "Save changes before closing?", bundle: .module)
        alert.informativeText = String(localized: "files.preview.discard_changes.message", defaultValue: "This preview has edits that have not been saved to the original file.", bundle: .module)
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save", bundle: .module))
        alert.addButton(withTitle: String(localized: "files.preview.discard_changes.discard", defaultValue: "Discard Changes", bundle: .module))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func workspaceFileCommandTarget() -> (worktreeID: UUID, tab: WorkspaceFileTab)? {
        if let activeTabID = FileBrowserKeyboardFocusState.activeWorkspaceFileEditorTabID,
           let target = workspaceFileTabMatch(tabID: activeTabID) {
            return target
        }

        if let selectedWorktreeID,
           workspacePrimaryViewModeByWorktreeID[selectedWorktreeID] == .files,
           let selectedTab = selectedWorkspaceFileTab(for: selectedWorktreeID) {
            return (selectedWorktreeID, selectedTab)
        }

        if let workspaceID = selectedWorkspace?.projectID,
           workspacePrimaryViewModeByWorktreeID[workspaceID] == .files,
           let selectedTab = selectedWorkspaceFileTab(for: workspaceID) {
            return (workspaceID, selectedTab)
        }

        for worktreeID in worktrees.map(\.id) where workspacePrimaryViewModeByWorktreeID[worktreeID] == .files {
            if let selectedTab = selectedWorkspaceFileTab(for: worktreeID) {
                return (worktreeID, selectedTab)
            }
        }

        return nil
    }

    private func workspaceFileTabMatch(tabID: String) -> (worktreeID: UUID, tab: WorkspaceFileTab)? {
        for (worktreeID, tabs) in workspaceFileTabsByWorktreeID {
            if let tab = tabs.first(where: { $0.id == tabID }) {
                return (worktreeID, tab)
            }
        }
        return nil
    }
}

private func uniqueWorkspaceFileTabs(_ tabs: [WorkspaceFileTab]) -> [WorkspaceFileTab] {
    var seenIDs = Set<String>()
    var resolved: [WorkspaceFileTab] = []

    for tab in tabs {
        var sanitized = tab
        sanitized.fileURL = tab.fileURL.standardizedFileURL
        sanitized.rootURL = tab.rootURL.standardizedFileURL
        let fallbackTitle = sanitized.fileURL.lastPathComponent
        let title = sanitized.title.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.title = title.isEmpty ? fallbackTitle : title

        guard !sanitized.id.isEmpty,
              seenIDs.insert(sanitized.id).inserted else {
            continue
        }

        resolved.append(sanitized)
    }

    return resolved
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
