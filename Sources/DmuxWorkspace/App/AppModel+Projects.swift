import AppKit
import Foundation

enum ProjectOpenApplication: String, CaseIterable, Identifiable, Sendable {
    case vsCode
    case terminal
    case iTerm2
    case ghostty
    case xcode
    case intellijIdea
    case webStorm
    case phpStorm
    case pyCharm
    case goLand
    case clion
    case rider
    case androidStudio
    case cursor
    case zed
    case sublimeText
    case windsurf

    var id: String { rawValue }

    static let ideApplications: [ProjectOpenApplication] = [
        .intellijIdea,
        .webStorm,
        .phpStorm,
        .pyCharm,
        .goLand,
        .clion,
        .rider,
        .androidStudio,
        .cursor,
        .zed,
        .sublimeText,
        .windsurf,
    ]

    var displayName: String {
        switch self {
        case .vsCode:
            return "VS Code"
        case .terminal:
            return "Terminal"
        case .iTerm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        case .xcode:
            return "Xcode"
        case .intellijIdea:
            return "IntelliJ IDEA"
        case .webStorm:
            return "WebStorm"
        case .phpStorm:
            return "PhpStorm"
        case .pyCharm:
            return "PyCharm"
        case .goLand:
            return "GoLand"
        case .clion:
            return "CLion"
        case .rider:
            return "Rider"
        case .androidStudio:
            return "Android Studio"
        case .cursor:
            return "Cursor"
        case .zed:
            return "Zed"
        case .sublimeText:
            return "Sublime Text"
        case .windsurf:
            return "Windsurf"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .vsCode:
            return ["com.microsoft.VSCode"]
        case .terminal:
            return ["com.apple.Terminal"]
        case .iTerm2:
            return ["com.googlecode.iterm2"]
        case .ghostty:
            return ["com.mitchellh.ghostty"]
        case .xcode:
            return ["com.apple.dt.Xcode"]
        case .intellijIdea:
            return ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .webStorm:
            return ["com.jetbrains.WebStorm"]
        case .phpStorm:
            return ["com.jetbrains.PhpStorm"]
        case .pyCharm:
            return ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]
        case .goLand:
            return ["com.jetbrains.goland"]
        case .clion:
            return ["com.jetbrains.CLion"]
        case .rider:
            return ["com.jetbrains.rider"]
        case .androidStudio:
            return ["com.google.android.studio"]
        case .cursor:
            return ["com.todesktop.230313mzl4w4u92", "com.yuxin.CursorPro"]
        case .zed:
            return ["dev.zed.Zed"]
        case .sublimeText:
            return ["com.sublimetext.4", "com.sublimetext.3"]
        case .windsurf:
            return ["com.exafunction.windsurf"]
        }
    }

    var primaryBundleIdentifier: String {
        bundleIdentifiers[0]
    }

    var installedBundleIdentifier: String? {
        bundleIdentifiers.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    var iconBundleIdentifier: String {
        installedBundleIdentifier ?? primaryBundleIdentifier
    }

    var fallbackSystemName: String {
        switch self {
        case .terminal, .iTerm2, .ghostty:
            return "terminal"
        case .xcode:
            return "hammer"
        case .vsCode:
            return "chevron.left.forwardslash.chevron.right"
        case .androidStudio, .cursor, .zed, .sublimeText, .windsurf:
            return "app.badge"
        case .intellijIdea, .webStorm, .phpStorm, .pyCharm, .goLand, .clion, .rider:
            return "curlybraces.square"
        }
    }

    var localizedOpenTitle: String {
        String(
            format: String(localized: "open.application.format", defaultValue: "Open in %@", bundle: .module),
            displayName
        )
    }

    var localizedSuccessMessage: String {
        String(
            format: String(localized: "project.open.application.success_format", defaultValue: "Opened project in %@.", bundle: .module),
            displayName
        )
    }

    var localizedFailureMessage: String {
        String(
            format: String(localized: "project.open.application.failure_format", defaultValue: "%@ not found.", bundle: .module),
            displayName
        )
    }
}

extension AppModel {
    func selectProject(_ projectID: UUID) {
        dismissCompletionPresentationIfNeeded(
            projectID: projectID,
            reason: "select-project"
        )
        updateSelectedProjectID(projectID, source: "selectProject")
        selectPreferredWorktree(for: projectID)
        clearTerminalFocusOutsideSelectedProject()
        restoreSelectedTerminalFocusIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard self?.selectedProjectID == projectID else {
                return
            }
            self?.clearTerminalFocusOutsideSelectedProject()
            self?.restoreSelectedTerminalFocusIfNeeded()
        }
        restoreCachedGitPanelIfAvailable(for: projectID)
        persist()
        refreshGitState()
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
    }

    func selectWorktree(_ worktreeID: UUID) {
        guard let worktree = worktrees.first(where: { $0.id == worktreeID }) else {
            statusMessage = String(localized: "worktree.not_found", defaultValue: "Worktree not found.", bundle: .module)
            return
        }
        if selectedProjectID != worktree.projectID {
            updateSelectedProjectID(worktree.projectID, source: "selectWorktree.project")
        }
        selectedWorktreeID = worktreeID
        let isReviewMode = workspacePrimaryViewModeByWorktreeID[worktreeID] == .review
        if isReviewMode {
            let shouldResetReviewFile = selectedWorktreeReviewID != worktreeID
            selectedWorktreeReviewID = worktreeID
            if shouldResetReviewFile {
                selectedWorktreeReviewFileID = nil
            }
            refreshWorktreeReview()
        }
        clearTerminalFocusOutsideSelectedProject()
        if isReviewMode {
            DmuxTerminalBackend.shared.registry.clearFocusedSession()
        } else {
            restoreSelectedTerminalFocusIfNeeded()
        }
        restoreCachedGitPanelIfAvailable(for: worktreeID)
        persist()
        refreshGitState()
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
    }

    func selectPreferredWorktree(for projectID: UUID) {
        if let selectedWorktreeID,
           worktrees.contains(where: { $0.id == selectedWorktreeID && $0.projectID == projectID }) {
            return
        }
        selectedWorktreeID = worktrees.first(where: { $0.projectID == projectID && $0.isDefault })?.id
            ?? worktrees.first(where: { $0.projectID == projectID })?.id
    }

    func selectProject(atSidebarIndex index: Int) {
        guard projects.indices.contains(index) else {
            return
        }
        selectProject(projects[index].id)
    }

    func moveProject(_ projectID: UUID, to targetProjectID: UUID, persists: Bool = true) {
        guard projectID != targetProjectID,
              let sourceIndex = projects.firstIndex(where: { $0.id == projectID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetProjectID }) else {
            return
        }

        var updatedProjects = projects
        let movedProject = updatedProjects.remove(at: sourceIndex)
        guard let adjustedTargetIndex = updatedProjects.firstIndex(where: { $0.id == targetProjectID }) else {
            return
        }

        let insertionIndex = sourceIndex < targetIndex
            ? min(adjustedTargetIndex + 1, updatedProjects.count)
            : adjustedTargetIndex
        updatedProjects.insert(movedProject, at: insertionIndex)

        guard updatedProjects.map(\.id) != projects.map(\.id) else {
            return
        }

        projects = updatedProjects
        let orderedWorkspaceIDs = projects.flatMap { project -> [UUID] in
            let worktreeIDs = worktrees.filter { $0.projectID == project.id }.map(\.id)
            return worktreeIDs.isEmpty ? [project.id] : worktreeIDs
        }
        workspaces = orderedWorkspaceIDs.compactMap { workspaceID in
            workspaces.first(where: { $0.projectID == workspaceID })
        }
        if persists {
            persistProjectOrder()
        }
    }

    func persistProjectOrder() {
        persist()
        refreshAIStatsIfNeeded()
    }

    func scheduleProjectOrderPersist() {
        scheduleDragReorderPersist(refreshAIStats: true)
    }

    func openRuntimeLog() {
        debugLog.log("app", "open runtime log")
        debugLog.openRuntimeLogInSystemViewer()
        statusMessage = String(localized: "app.runtime_log.opened", defaultValue: "Opened runtime log.", bundle: .module)
    }

    func openLiveLog() {
        debugLog.log("app", "open live log")
        debugLog.openLiveLogInSystemViewer()
        statusMessage = String(localized: "app.live_log.opened", defaultValue: "Opened live log.", bundle: .module)
    }

    func exportDiagnosticsArchive() {
        do {
            let destinationURL = try diagnosticsExportService.requestExportDestination(appDisplayName: appDisplayName)
            statusMessage = String(localized: "diagnostics.export.running", defaultValue: "Exporting diagnostics…", bundle: .module)

            let appDisplayName = self.appDisplayName
            let appVersionDescription = self.appVersionDescription
            Task.detached(priority: .userInitiated) {
                do {
                    let archiveURL = try AppDiagnosticsExportService().exportArchive(
                        to: destinationURL,
                        appDisplayName: appDisplayName,
                        appVersion: appVersionDescription
                    )
                    await MainActor.run {
                        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                        self.statusMessage = String(
                            format: String(localized: "diagnostics.export.success_format", defaultValue: "Exported diagnostics to %@.", bundle: .module),
                            archiveURL.lastPathComponent
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.debugLog.log("diagnostics-export", "failed error=\(error.localizedDescription)")
                        self.presentDiagnosticsExportError(error)
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            debugLog.log("diagnostics-export", "failed error=\(error.localizedDescription)")
            presentDiagnosticsExportError(error)
        }
    }

    func openSelectedProjectInVSCode() {
        openSelectedProject(in: .vsCode)
    }

    func openSelectedProject(in application: ProjectOpenApplication) {
        guard let project = selectedProject else {
            statusMessage = String(localized: "project.none_selected", defaultValue: "No project selected.", bundle: .module)
            return
        }
        openProject(project, in: application)
    }

    func openProject(_ projectID: UUID, in application: ProjectOpenApplication) {
        let project = selectedProjectID == projectID
            ? selectedProject
            : projects.first(where: { $0.id == projectID })
        guard let project else {
            statusMessage = String(localized: "project.not_found", defaultValue: "Project not found.", bundle: .module)
            return
        }
        openProject(project, in: application)
    }

    func revealSelectedProjectInFinder() {
        guard let project = selectedProject else {
            statusMessage = String(localized: "project.none_selected", defaultValue: "No project selected.", bundle: .module)
            return
        }

        revealProjectInFinder(project.id)
    }

    func revealProjectInFinder(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            statusMessage = String(localized: "project.not_found", defaultValue: "Project not found.", bundle: .module)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path, isDirectory: true)])
        statusMessage = String(localized: "project.reveal.finder.success", defaultValue: "Revealed project in Finder.", bundle: .module)
    }

    func openProjectDirectory(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            statusMessage = String(localized: "project.not_found", defaultValue: "Project not found.", bundle: .module)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true))
        statusMessage = String(localized: "project.open.folder.success", defaultValue: "Opened project folder.", bundle: .module)
    }

    func openSelectedProjectInTerminal() {
        openSelectedProject(in: .terminal)
    }

    func openSelectedProjectInITerm2() {
        openSelectedProject(in: .iTerm2)
    }

    func openSelectedProjectInGhostty() {
        openSelectedProject(in: .ghostty)
    }

    func openSelectedProjectInXcode() {
        openSelectedProject(in: .xcode)
    }

    func addProject() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            debugLog.log("project-create", "open-dialog failed reason=main-window-missing")
            return
        }
        debugLog.log("project-create", "open-dialog")

        let dialog = ProjectEditorDialogState(
            title: String(localized: "project.create.title", defaultValue: "Create Project", bundle: .module),
            message: String(localized: "project.create.message", defaultValue: "Fill in the project name, directory, color, and icon.", bundle: .module),
            confirmTitle: String(localized: "common.create", defaultValue: "Create", bundle: .module),
            name: "",
            path: "",
            badgeText: "",
            badgeSymbol: nil,
            badgeColorHex: systemAccentHexString()
        )

        ProjectEditorPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.debugLog.log("project-create", "dialog cancelled")
                return
            }
            self.debugLog.log(
                "project-create",
                "dialog confirmed name=\(result.name) path=\(result.path) symbol=\(result.badgeSymbol ?? "nil") color=\(result.badgeColorHex)"
            )
            self.importProject(
                name: result.name.trimmingCharacters(in: .whitespacesAndNewlines),
                path: result.path.trimmingCharacters(in: .whitespacesAndNewlines),
                badgeText: result.badgeText,
                badgeSymbol: result.badgeSymbol,
                badgeColorHex: result.badgeColorHex
            )
        }
    }

    func openProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "project.open_folder.title", defaultValue: "Open Folder", bundle: .module)
        panel.prompt = String(localized: "project.open_folder.prompt", defaultValue: "Open", bundle: .module)
        panel.message = String(localized: "project.open_folder.message", defaultValue: "Choose a project folder to import.", bundle: .module)

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else {
                return
            }
            guard response == .OK, let url = panel.url else {
                self.debugLog.log("project-create", "open-folder cancelled")
                return
            }
            self.debugLog.log("project-create", "open-folder selected path=\(url.path)")
            self.importProject(
                name: url.lastPathComponent,
                path: url.path,
                badgeText: "",
                badgeSymbol: nil,
                badgeColorHex: systemAccentHexString()
            )
        }

        if let parentWindow = presentationWindow() {
            panel.beginSheetModal(for: parentWindow, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func editProject(_ projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let project = projects[index]
        let dialog = ProjectEditorDialogState(
            title: String(localized: "project.edit.title", defaultValue: "Edit Project", bundle: .module),
            message: String(localized: "project.edit.message", defaultValue: "Update the project name, directory, color, and icon.", bundle: .module),
            confirmTitle: String(localized: "common.save", defaultValue: "Save", bundle: .module),
            name: project.name,
            path: project.path,
            badgeText: project.badgeText ?? "",
            badgeSymbol: project.badgeSymbol,
            badgeColorHex: project.badgeColorHex ?? systemAccentHexString()
        )

        ProjectEditorPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, let result else { return }
            appendProjectEditLog("[EditProjectResult] id=\(projectID.uuidString) name=\(result.name) symbol=\(result.badgeSymbol ?? "nil") color=\(result.badgeColorHex)")

            let updatedProject = Project(
                id: project.id,
                name: result.name.trimmingCharacters(in: .whitespacesAndNewlines),
                path: result.path.trimmingCharacters(in: .whitespacesAndNewlines),
                shell: project.shell,
                defaultCommand: project.defaultCommand,
                badgeText: result.badgeText,
                badgeSymbol: result.badgeSymbol,
                badgeColorHex: result.badgeColorHex,
                gitDefaultPushRemoteName: project.gitDefaultPushRemoteName
            )
            var updatedProjects = self.projects
            updatedProjects[index] = updatedProject
            self.projects = updatedProjects

            if let worktreeIndex = self.worktrees.firstIndex(where: { $0.projectID == projectID && $0.isDefault }) {
                self.worktrees[worktreeIndex].path = updatedProject.path
                self.worktrees[worktreeIndex].updatedAt = Date()
            }
            var updatedWorkspaces = self.workspaces
            for workspaceIndex in updatedWorkspaces.indices {
                guard let worktree = self.worktrees.first(where: { $0.id == updatedWorkspaces[workspaceIndex].projectID && $0.projectID == projectID }) else {
                    continue
                }
                let effectiveName = worktree.isDefault ? updatedProject.name : "\(updatedProject.name) · \(worktree.name)"
                for sessionIndex in updatedWorkspaces[workspaceIndex].sessions.indices {
                    updatedWorkspaces[workspaceIndex].sessions[sessionIndex].projectName = effectiveName
                    updatedWorkspaces[workspaceIndex].sessions[sessionIndex].cwd = worktree.path
                    updatedWorkspaces[workspaceIndex].sessions[sessionIndex].shell = updatedProject.shell
                }
            }
            self.workspaces = updatedWorkspaces

            self.statusMessage = String(
                format: String(localized: "project.update.success_format", defaultValue: "Updated project %@.", bundle: .module),
                updatedProject.name
            )
            self.persist()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(AppSnapshot(projects: self.projects, worktrees: self.worktrees, worktreeTasks: self.worktreeTasks, workspaces: self.workspaces, selectedProjectID: self.selectedProjectID, selectedWorktreeID: self.selectedWorktreeID, workspaceContentStates: self.workspaceContentStatesSnapshot(), appSettings: self.appSettings, taskMemos: self.taskMemos, sshProfiles: self.sshProfiles)),
               let encoded = String(data: data, encoding: .utf8) {
                appendProjectEditLog("[PersistSnapshot] \(encoded)")
            }
            self.refreshGitState()
            self.refreshAIStatsIfNeeded()
        }
    }

    func removeProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = ConfirmDialogState(
            title: String(localized: "project.remove.title", defaultValue: "Remove Project", bundle: .module),
            message: String(
                format: String(localized: "project.remove.confirm_format", defaultValue: "Are you sure you want to remove project %@? Files on disk will not be deleted.", bundle: .module),
                project.name
            ),
            icon: "trash",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.remove", defaultValue: "Remove", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            self.petStore.forgetProjectBaseline(projectID)
            self.projects.removeAll { $0.id == projectID }
            let removedWorktreeIDs = Set(self.worktrees.filter { $0.projectID == projectID }.map(\.id))
            self.worktrees.removeAll { $0.projectID == projectID }
            self.workspaces.removeAll { removedWorktreeIDs.contains($0.projectID) }
            self.workspaceFileTabsByWorktreeID = self.workspaceFileTabsByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
            self.selectedWorkspaceContentByWorktreeID = self.selectedWorkspaceContentByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
            self.workspacePrimaryViewModeByWorktreeID = self.workspacePrimaryViewModeByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
            self.worktreeTasks.removeAll { removedWorktreeIDs.contains($0.worktreeID) }
            if self.selectedProjectID == projectID {
                self.updateSelectedProjectID(self.projects.first?.id, source: "removeProject")
                if let nextProjectID = self.selectedProjectID {
                    self.selectPreferredWorktree(for: nextProjectID)
                } else {
                    self.selectedWorktreeID = nil
                }
            }
            self.statusMessage = String(
                format: String(localized: "project.remove.success_format", defaultValue: "Removed project %@.", bundle: .module),
                project.name
            )
            self.persist()
            self.refreshGitState()
            self.updateGitRemoteSyncPolling()
            self.refreshAIStatsIfNeeded()
        }
    }

    func closeCurrentProject() {
        guard let project = selectedRootProject else {
            return
        }

        petStore.forgetProjectBaseline(project.id)
        projects.removeAll { $0.id == project.id }
        let removedWorktreeIDs = Set(worktrees.filter { $0.projectID == project.id }.map(\.id))
        worktrees.removeAll { $0.projectID == project.id }
        workspaces.removeAll { removedWorktreeIDs.contains($0.projectID) }
        workspaceFileTabsByWorktreeID = workspaceFileTabsByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
        selectedWorkspaceContentByWorktreeID = selectedWorkspaceContentByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
        workspacePrimaryViewModeByWorktreeID = workspacePrimaryViewModeByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
        worktreeTasks.removeAll { removedWorktreeIDs.contains($0.worktreeID) }
        updateSelectedProjectID(projects.first?.id, source: "closeCurrentProject")
        if let selectedProjectID {
            selectPreferredWorktree(for: selectedProjectID)
        } else {
            selectedWorktreeID = nil
        }
        statusMessage = String(
            format: String(localized: "project.close.success_format", defaultValue: "Closed project %@.", bundle: .module),
            project.name
        )
        persist()
        refreshGitState()
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
    }

    func closeAllProjects() {
        guard !projects.isEmpty else {
            return
        }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "workspace.close_all_projects.title", defaultValue: "Close All Projects", bundle: .module),
            message: String(localized: "workspace.close_all_projects.message", defaultValue: "Are you sure you want to close all projects in the current workspace? Files on disk will not be deleted.", bundle: .module),
            icon: "xmark.rectangle.stack",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "workspace.close_all_projects.confirm", defaultValue: "Close All", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            self.petStore.forgetProjectBaselines(self.projects.map(\.id))
            self.projects.removeAll()
            self.worktrees.removeAll()
            self.workspaces.removeAll()
            self.workspaceFileTabsByWorktreeID.removeAll()
            self.selectedWorkspaceContentByWorktreeID.removeAll()
            self.workspacePrimaryViewModeByWorktreeID.removeAll()
            self.worktreeTasks.removeAll()
            self.selectedWorktreeReviewID = nil
            self.selectedWorktreeReviewFileID = nil
            self.worktreeReviewSnapshot = nil
            self.updateSelectedProjectID(nil, source: "closeAllProjects")
            self.selectedWorktreeID = nil
            self.rightPanel = nil
            self.statusMessage = String(localized: "workspace.close_all_projects.success", defaultValue: "Closed all projects.", bundle: .module)
            self.persist()
            self.refreshGitState()
            self.updateGitRemoteSyncPolling()
            self.refreshAIStatsIfNeeded()
        }
    }

    func toggleRightPanel(_ kind: RightPanelKind) {
        let wasShowingGitPanel = rightPanel == .git
        if rightPanel == kind {
            rightPanel = nil
        } else {
            rightPanel = kind
        }
        if rightPanel == .git && wasShowingGitPanel == false {
            refreshGitState(presentation: .preserveVisibleState)
        }
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
    }

    func cancelCurrentAIIndexing() {
        aiStatsStore.cancelCurrent(project: selectedProject, projects: projects)
        interruptCurrentAIRuntime(reason: "ai-stats-stop")
    }

    func interruptCurrentAIRuntime(reason: String) {
        let focusedSessionID = DmuxTerminalBackend.shared.registry.focusedSessionID()
        let candidateSessionID = focusedSessionID ?? selectedSessionID
        guard let sessionID = candidateSessionID else {
            debugLog.log("runtime-interrupt", "skip reason=\(reason) session=nil")
            return
        }

        let tool = aiSessionStore.tool(for: sessionID)
        let isRealtimeTool = tool.map { toolDriverFactory.isRealtimeTool($0) } ?? false
        let isRunning = aiSessionStore.isRunning(terminalID: sessionID)
        let shellPID = DmuxTerminalBackend.shared.registry.shellPID(for: sessionID)
        let activeTool = shellPID.flatMap { TerminalProcessInspector().activeTool(forShellPID: $0) }

        guard isRealtimeTool, isRunning else {
            debugLog.log(
                "runtime-interrupt",
                "skip reason=\(reason) session=\(sessionID.uuidString) focused=\(focusedSessionID?.uuidString ?? "nil") tool=\(tool ?? "nil") realtime=\(isRealtimeTool) running=\(isRunning) shellPID=\(shellPID.map(String.init) ?? "nil") activeTool=\(activeTool ?? "nil")"
            )
            return
        }

        terminalFocusRequestID = sessionID
        let didSendEscape = DmuxTerminalBackend.shared.registry.sendEscape(to: sessionID)
        let didSendInterrupt = didSendEscape ? false : DmuxTerminalBackend.shared.registry.sendInterrupt(to: sessionID)
        let didMarkInterrupted = aiSessionStore.markInterrupted(terminalID: sessionID)
        refreshProjectActivity(sendNotifications: true)
        if let selectedProject {
            aiStatsStore.refreshLiveState(
                project: selectedProject,
                selectedSessionID: selectedSessionID,
                reason: .runtimeBridge
            )
        }

        debugLog.log(
            "runtime-interrupt",
            "sent reason=\(reason) session=\(sessionID.uuidString) focused=\(focusedSessionID?.uuidString ?? "nil") tool=\(tool ?? "nil") shellPID=\(shellPID.map(String.init) ?? "nil") activeTool=\(activeTool ?? "nil") escape=\(didSendEscape) interrupt=\(didSendInterrupt) marked=\(didMarkInterrupted)"
        )
    }

    func refreshCurrentAIIndexing() {
        aiStatsStore.refreshCurrent(project: selectedProject, projects: projects, selectedSessionID: selectedSessionID)
    }

    func aiSessionCapabilities(for session: AISessionSummary) -> AIToolSessionCapabilities {
        toolDriverFactory.sessionCapabilities(for: session)
    }

    func openAISession(_ session: AISessionSummary) {
        guard let command = toolDriverFactory.resumeCommand(for: session) else {
            debugLog.log(
                "ai-session-open",
                "unsupported session=\(session.sessionID.uuidString) tool=\(session.lastTool ?? "nil") external=\(session.externalSessionID ?? "nil") reason=missing-command"
            )
            statusMessage = String(localized: "ai.session.open.unsupported", defaultValue: "This session does not support opening.", bundle: .module)
            return
        }
        guard let tool = session.lastTool?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else {
            debugLog.log(
                "ai-session-open",
                "unsupported session=\(session.sessionID.uuidString) tool=nil external=\(session.externalSessionID ?? "nil") reason=missing-tool"
            )
            statusMessage = String(localized: "ai.session.open.unsupported", defaultValue: "This session does not support opening.", bundle: .module)
            return
        }
        guard let externalSessionID = session.externalSessionID, !externalSessionID.isEmpty else {
            debugLog.log(
                "ai-session-open",
                "unsupported session=\(session.sessionID.uuidString) tool=\(tool) external=nil reason=missing-external"
            )
            statusMessage = String(localized: "ai.session.identifier.missing", defaultValue: "Missing session identifier.", bundle: .module)
            return
        }
        debugLog.log(
            "ai-session-open",
            "request source=indexed session=\(session.sessionID.uuidString) selected=\(selectedSessionID?.uuidString ?? "nil") tool=\(tool) external=\(externalSessionID) command=\(command)"
        )

        if let selectedSessionID = selectedSessionID {
            aiSessionStore.registerExpectedLogicalSession(
                terminalID: selectedSessionID,
                tool: tool,
                aiSessionID: externalSessionID
            )
        }
        if tryReuseSelectedTopTerminalForCommand(command) {
            debugLog.log(
                "ai-session-open",
                "reuse-current selected=\(selectedSessionID?.uuidString ?? "nil") tool=\(tool) external=\(externalSessionID) command=\(command)"
            )
            statusMessage = String(localized: "ai.session.open.current_success", defaultValue: "Opened session in the current terminal.", bundle: .module)
            return
        }
        if let selectedSessionID = selectedSessionID {
            aiSessionStore.clearExpectedLogicalSession(terminalID: selectedSessionID)
        }

        guard let newSessionID = createSplitTerminalRunningCommandInShell(command: command, axis: .horizontal) else {
            statusMessage = String(localized: "workspace.split.create_failed", defaultValue: "Unable to create a new split pane.", bundle: .module)
            return
        }
        aiSessionStore.registerExpectedLogicalSession(
            terminalID: newSessionID,
            tool: tool,
            aiSessionID: externalSessionID
        )
        debugLog.log(
            "ai-session-open",
            "create-split newSession=\(newSessionID.uuidString) tool=\(tool) external=\(externalSessionID) command=\(command)"
        )
        terminalFocusRequestID = newSessionID
        statusMessage = String(localized: "ai.session.open.split_success", defaultValue: "Opened session in a new split pane.", bundle: .module)
    }

    func renameAISession(_ session: AISessionSummary) {
        let capabilities = aiSessionCapabilities(for: session)
        guard capabilities.canRename else {
            statusMessage = String(localized: "ai.session.rename.unsupported", defaultValue: "This session does not support renaming.", bundle: .module)
            return
        }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = GitInputDialogState(
            kind: .renameAISession,
            title: String(localized: "ai.session.rename.title", defaultValue: "Rename Session", bundle: .module),
            message: String(localized: "ai.session.rename.message", defaultValue: "Directly update the local session title for the corresponding AI CLI.", bundle: .module),
            placeholder: String(localized: "ai.session.rename.placeholder", defaultValue: "Enter a New Session Title", bundle: .module),
            confirmTitle: String(localized: "common.save", defaultValue: "Save", bundle: .module),
            value: session.sessionTitle,
            isMultiline: false
        )
        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] value in
            guard let self, let value else {
                return
            }
            let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                self.statusMessage = String(localized: "ai.session.rename.empty", defaultValue: "Session title cannot be empty.", bundle: .module)
                return
            }

            do {
                try self.toolDriverFactory.renameSession(session, to: title)
                self.aiStatsStore.renameSessionOptimistically(projectID: session.projectID, sessionID: session.sessionID, title: title)
                self.invalidateAISessionCachesAndRefresh()
                self.statusMessage = String(localized: "ai.session.rename.success", defaultValue: "Renamed session.", bundle: .module)
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func removeAISession(_ session: AISessionSummary) {
        let capabilities = aiSessionCapabilities(for: session)
        guard capabilities.canRemove else {
            statusMessage = String(localized: "ai.session.remove.unsupported", defaultValue: "This session does not support removal.", bundle: .module)
            return
        }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "ai.session.remove.title", defaultValue: "Remove Session", bundle: .module),
            message: String(localized: "ai.session.remove.confirm", defaultValue: "This will directly modify the local session storage for the corresponding AI CLI. Continue?", bundle: .module),
            icon: "trash",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.remove", defaultValue: "Remove", bundle: .module),
            primaryTint: AppTheme.warning,
            secondaryTitle: nil,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else {
                return
            }

            do {
                try self.toolDriverFactory.removeSession(session)
                self.aiStatsStore.removeSessionOptimistically(projectID: session.projectID, sessionID: session.sessionID)
                self.invalidateAISessionCachesAndRefresh()
                self.statusMessage = String(localized: "ai.session.remove.success", defaultValue: "Removed session.", bundle: .module)
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func invalidateAISessionCachesAndRefresh() {
        guard let project = selectedProject else {
            return
        }
        aiStatsStore.invalidateProjectCaches(project: project)
        refreshCurrentAIIndexing()
    }

    func updateSelectedProjectID(_ projectID: UUID?, source: String) {
        selectedProjectIDChangeSource = source
        selectedProjectID = projectID
        if selectedProjectID == projectID {
            selectedProjectIDChangeSource = "unspecified"
        }
        if let projectID {
            selectPreferredWorktree(for: projectID)
        } else {
            selectedWorktreeID = nil
        }
    }

    private func openProject(_ project: Project, in application: ProjectOpenApplication) {
        openProjectInApplication(
            project,
            bundleIdentifiers: application.bundleIdentifiers,
            fallbackURL: application == .vsCode ? vscodeOpenURL(for: project.path) : nil,
            successMessage: application.localizedSuccessMessage,
            failureMessage: application.localizedFailureMessage
        )
    }

    private func openProjectInApplication(_ project: Project, bundleIdentifiers: [String], fallbackURL: URL? = nil, successMessage: String, failureMessage: String) {
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        if let bundleIdentifier = bundleIdentifiers.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
            Task { [weak self, projectURL, bundleIdentifier, fallbackURL, successMessage, failureMessage] in
                let didOpen = await Task.detached(priority: .userInitiated) {
                    Self.openProjectURL(projectURL, withBundleIdentifier: bundleIdentifier)
                }.value

                guard let self else { return }
                if didOpen {
                    self.statusMessage = successMessage
                } else if let fallbackURL, NSWorkspace.shared.open(fallbackURL) {
                    self.statusMessage = successMessage
                } else {
                    self.statusMessage = failureMessage
                }
            }
            return
        }

        if let fallbackURL, NSWorkspace.shared.open(fallbackURL) {
            statusMessage = successMessage
            return
        }

        statusMessage = failureMessage
    }

    private nonisolated static func openProjectURL(_ projectURL: URL, withBundleIdentifier bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier, projectURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func vscodeOpenURL(for path: String) -> URL? {
        guard var components = URLComponents(string: "vscode://file") else {
            return nil
        }

        var normalizedPath = URL(fileURLWithPath: path, isDirectory: true).path
        if !normalizedPath.hasSuffix("/") {
            normalizedPath += "/"
        }
        components.percentEncodedPath = normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedPath
        return components.url
    }

    func importProject(name: String, path: String, badgeText: String, badgeSymbol: String?, badgeColorHex: String) {
        let rawPath = (path as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        debugLog.log(
            "project-create",
            "import start rawPath=\(path) normalizedPath=\(normalizedPath) name=\(name) symbol=\(badgeSymbol ?? "nil") color=\(badgeColorHex)"
        )
        guard !normalizedPath.isEmpty else {
            statusMessage = String(localized: "project.path.empty", defaultValue: "Project path cannot be empty.", bundle: .module)
            debugLog.log("project-create", "import failed reason=empty-path")
            return
        }

        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                statusMessage = String(localized: "project.path.invalid_directory", defaultValue: "Project path must be a folder.", bundle: .module)
                debugLog.log("project-create", "import failed reason=path-is-file path=\(normalizedPath)")
                return
            }
            debugLog.log("project-create", "path exists path=\(normalizedPath)")
        } else {
            do {
                debugLog.log("project-create", "creating directory path=\(normalizedPath)")
                try fileManager.createDirectory(atPath: normalizedPath, withIntermediateDirectories: true, attributes: nil)
                debugLog.log("project-create", "created directory path=\(normalizedPath)")
            } catch {
                statusMessage = String(
                    format: String(localized: "project.path.create_failed", defaultValue: "Failed to create project folder: %@.", bundle: .module),
                    error.localizedDescription
                )
                debugLog.log("project-create", "import failed reason=create-directory error=\(error.localizedDescription) path=\(normalizedPath)")
                return
            }
        }

        if let existing = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath }) {
            updateSelectedProjectID(existing.id, source: "importProject.existing")
            selectPreferredWorktree(for: existing.id)
            statusMessage = String(localized: "project.exists.switched", defaultValue: "Project already exists. Switched to it.", bundle: .module)
            debugLog.log("project-create", "switched-to-existing projectID=\(existing.id.uuidString) path=\(normalizedPath)")
            refreshGitState()
            updateGitRemoteSyncPolling()
            refreshAIStatsIfNeeded()
            return
        }

        let project = Project(
            id: UUID(),
            name: name.isEmpty ? URL(fileURLWithPath: normalizedPath).lastPathComponent : name,
            path: normalizedPath,
            shell: appSettings.defaultTerminal.shellPath,
            defaultCommand: "",
            badgeText: badgeText,
            badgeSymbol: badgeSymbol,
            badgeColorHex: badgeColorHex,
            gitDefaultPushRemoteName: nil
        )
        debugLog.log("project-create", "project-created id=\(project.id.uuidString) name=\(project.name) path=\(project.path)")
        projects.append(project)
        let defaultWorktree = ProjectWorktree.defaultWorktree(for: project)
        worktrees.append(defaultWorktree)
        workspaces.append(ProjectWorkspace.sample(projectID: project.id, path: project.path))
        updateSelectedProjectID(project.id, source: "importProject.created")
        selectedWorktreeID = defaultWorktree.id
        statusMessage = String(
            format: String(localized: "project.add.success_format", defaultValue: "Added project %@.", bundle: .module),
            project.name
        )
        debugLog.log("project-create", "persist begin projectID=\(project.id.uuidString)")
        persist()
        debugLog.log("project-create", "persist complete projectID=\(project.id.uuidString)")
        refreshGitState()
        debugLog.log("project-create", "git refresh requested projectID=\(project.id.uuidString)")
        updateGitRemoteSyncPolling()
        refreshAIStatsIfNeeded()
        debugLog.log("project-create", "import complete projectID=\(project.id.uuidString)")
    }
}
