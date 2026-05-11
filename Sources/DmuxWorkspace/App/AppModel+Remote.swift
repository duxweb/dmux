import Foundation

extension AppModel {
  func remoteProjects() -> [[String: String]] {
    projects.map { project in
      [
        "id": project.id.uuidString,
        "name": project.name,
        "path": project.path,
      ]
    }
  }

  func remoteDesktopTerminals() -> [TerminalSession] {
    var sessionsByID: [UUID: TerminalSession] = [:]
    var orderedIDs: [UUID] = []

    for workspace in workspaces {
      for sessionID in workspace.visibleSessionIDs {
        guard let session = workspace.session(for: sessionID) else { continue }
        if sessionsByID[sessionID] == nil {
          orderedIDs.append(sessionID)
        }
        sessionsByID[sessionID] = session
      }
    }

    return orderedIDs.compactMap { sessionsByID[$0] }
  }

  func remoteCreateTerminal(projectID: String?, command: String) -> TerminalSession? {
    let resolvedProject: Project?
    let resolvedWorktreeID: UUID?
    if let projectID, let uuid = UUID(uuidString: projectID) {
      if let worktree = worktrees.first(where: { $0.id == uuid }) {
        resolvedWorktreeID = worktree.id
        resolvedProject = projectForWorktree(worktree)
      } else if let worktree = worktrees.first(where: { $0.projectID == uuid && $0.isDefault }) {
        resolvedWorktreeID = worktree.id
        resolvedProject = projectForWorktree(worktree)
      } else {
        resolvedWorktreeID = nil
        resolvedProject = projects.first { $0.id == uuid }
      }
    } else if selectedProjectID != nil {
      resolvedWorktreeID = selectedWorktreeID
      resolvedProject = selectedProject
    } else {
      let worktree = worktrees.first
      resolvedWorktreeID = worktree?.id
      resolvedProject = worktree.flatMap { projectForWorktree($0) } ?? projects.first
    }
    guard let project = resolvedProject,
      let workspaceID = resolvedWorktreeID ?? worktrees.first(where: { $0.projectID == project.id && $0.isDefault })?.id ?? Optional(project.id)
    else {
      return nil
    }
    guard let workspaceIndex = workspaces.firstIndex(where: { $0.projectID == workspaceID }) else {
      return nil
    }

    let effectiveCommand = command.isEmpty ? project.defaultCommand : command
    let session = TerminalSession.make(project: project, command: effectiveCommand)
    var updatedWorkspaces = workspaces
    updatedWorkspaces[workspaceIndex].sessions.append(session)
    if updatedWorkspaces[workspaceIndex].addTopSession(session.id) == false {
      updatedWorkspaces[workspaceIndex].addBottomTab(session.id)
    }
    workspaces = updatedWorkspaces
    if selectedWorktreeID == workspaceID {
      terminalFocusRequestID = session.id
      terminalFocusRenderVersion &+= 1
    }
    persist()
    refreshAIStatsIfNeeded()
    return session
  }

  func remoteAddProject(path: String, name: String?) -> Project? {
    let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    if let existing = projects.first(where: {
      URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath
    }) {
      updateSelectedProjectID(existing.id, source: "remoteAddProject.existing")
      selectPreferredWorktree(for: existing.id)
      return existing
    }
    let project = Project(
      id: UUID(),
      name: remoteProjectName(name: name, path: normalizedPath),
      path: normalizedPath,
      shell: appSettings.defaultTerminal.shellPath,
      defaultCommand: "",
      badgeText: nil,
      badgeSymbol: nil,
      badgeColorHex: nil,
      gitDefaultPushRemoteName: nil
    )
    projects.append(project)
    let defaultWorktree = ProjectWorktree.defaultWorktree(for: project)
    worktrees.append(defaultWorktree)
    workspaces.append(ProjectWorkspace.sample(projectID: project.id, path: project.path))
    updateSelectedProjectID(project.id, source: "remoteAddProject.created")
    selectedWorktreeID = defaultWorktree.id
    persist()
    refreshGitState()
    updateGitRemoteSyncPolling()
    refreshAIStatsIfNeeded()
    return project
  }

  func remoteEditProject(projectID: String, path: String, name: String?) -> Project? {
    guard let uuid = UUID(uuidString: projectID),
      let index = projects.firstIndex(where: { $0.id == uuid })
    else { return nil }
    let current = projects[index]
    let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    let updated = Project(
      id: current.id,
      name: remoteProjectName(name: name, path: normalizedPath),
      path: normalizedPath,
      shell: current.shell,
      defaultCommand: current.defaultCommand,
      badgeText: current.badgeText,
      badgeSymbol: current.badgeSymbol,
      badgeColorHex: current.badgeColorHex,
      gitDefaultPushRemoteName: current.gitDefaultPushRemoteName
    )
    projects[index] = updated
    if let worktreeIndex = worktrees.firstIndex(where: { $0.projectID == uuid && $0.isDefault }) {
      worktrees[worktreeIndex].path = normalizedPath
      worktrees[worktreeIndex].updatedAt = Date()
    }
    for workspaceIndex in workspaces.indices {
      guard let worktree = worktrees.first(where: { $0.id == workspaces[workspaceIndex].projectID && $0.projectID == uuid }) else {
        continue
      }
      let effectiveName = worktree.isDefault ? updated.name : "\(updated.name) · \(worktree.name)"
      for sessionIndex in workspaces[workspaceIndex].sessions.indices {
        workspaces[workspaceIndex].sessions[sessionIndex].projectName = effectiveName
        workspaces[workspaceIndex].sessions[sessionIndex].cwd = worktree.path
        workspaces[workspaceIndex].sessions[sessionIndex].shell = updated.shell
      }
    }
    updateSelectedProjectID(updated.id, source: "remoteEditProject")
    persist()
    refreshGitState()
    updateGitRemoteSyncPolling()
    refreshAIStatsIfNeeded()
    return updated
  }

  func remoteRemoveProject(projectID: String) -> Bool {
    guard let uuid = UUID(uuidString: projectID),
      projects.contains(where: { $0.id == uuid })
    else { return false }
    petStore.forgetProjectBaseline(uuid)
    projects.removeAll { $0.id == uuid }
    let removedWorktreeIDs = Set(worktrees.filter { $0.projectID == uuid }.map(\.id))
    worktrees.removeAll { $0.projectID == uuid }
    workspaces.removeAll { removedWorktreeIDs.contains($0.projectID) }
    workspaceFileTabsByWorktreeID = workspaceFileTabsByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
    selectedWorkspaceContentByWorktreeID = selectedWorkspaceContentByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
    workspacePrimaryViewModeByWorktreeID = workspacePrimaryViewModeByWorktreeID.filter { !removedWorktreeIDs.contains($0.key) }
    worktreeTasks.removeAll { removedWorktreeIDs.contains($0.worktreeID) }
    if selectedProjectID == uuid {
      updateSelectedProjectID(projects.first?.id, source: "remoteRemoveProject")
      if let selectedProjectID {
        selectPreferredWorktree(for: selectedProjectID)
      } else {
        selectedWorktreeID = nil
      }
    }
    persist()
    refreshGitState()
    updateGitRemoteSyncPolling()
    refreshAIStatsIfNeeded()
    return true
  }

  func remoteAIStats(projectID: String) -> [String: Any]? {
    guard let uuid = UUID(uuidString: projectID),
      let project = projects.first(where: { $0.id == uuid })
    else { return nil }
    let liveContext = aiStatsStore.liveSnapshotContext(
      projectID: uuid, selectedSessionID: selectedSessionID)
    let state =
      aiStatsStore.cachedState(for: uuid)
      ?? aiStatsStore.aiUsageService.snapshotBackedPanelState(
        project: project,
        liveSnapshots: liveContext.summary,
        currentSnapshot: liveContext.current,
        status: .idle
      )
    let summary = state.projectSummary
    let requestCount = state.sessions.reduce(0) { $0 + $1.requestCount }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let liveSessions = state.liveSnapshots.map { snapshot -> [String: Any] in
      var item: [String: Any] = [
        "sessionId": snapshot.sessionID.uuidString,
        "title": snapshot.sessionTitle,
        "projectId": snapshot.projectID.uuidString,
        "projectName": snapshot.projectName,
        "status": snapshot.status,
        "isRunning": snapshot.isRunning,
        "inputTokens": snapshot.currentInputTokens,
        "outputTokens": snapshot.currentOutputTokens,
        "totalTokens": snapshot.currentTotalTokens,
        "cachedInputTokens": snapshot.currentCachedInputTokens,
        "updatedAt": formatter.string(from: snapshot.updatedAt),
      ]
      if let externalSessionID = snapshot.externalSessionID {
        item["externalSessionId"] = externalSessionID
      }
      if let tool = snapshot.tool { item["tool"] = tool }
      if let model = snapshot.model { item["model"] = model }
      if let usage = snapshot.currentContextUsagePercent { item["contextUsagePercent"] = usage }
      return item
    }
    let todayTimeBuckets = state.todayTimeBuckets.map { bucket -> [String: Any] in
      [
        "start": formatter.string(from: bucket.start),
        "end": formatter.string(from: bucket.end),
        "totalTokens": bucket.totalTokens,
        "cachedInputTokens": bucket.cachedInputTokens,
        "requestCount": bucket.requestCount,
      ]
    }
    let heatmap = state.heatmap.map { day -> [String: Any] in
      [
        "day": formatter.string(from: day.day),
        "totalTokens": day.totalTokens,
        "cachedInputTokens": day.cachedInputTokens,
        "requestCount": day.requestCount,
      ]
    }
    let toolBreakdown = state.toolBreakdown.map { item -> [String: Any] in
      [
        "key": item.key,
        "totalTokens": item.totalTokens,
        "cachedInputTokens": item.cachedInputTokens,
        "requestCount": item.requestCount,
      ]
    }
    let modelBreakdown = state.modelBreakdown.map { item -> [String: Any] in
      [
        "key": item.key,
        "totalTokens": item.totalTokens,
        "cachedInputTokens": item.cachedInputTokens,
        "requestCount": item.requestCount,
      ]
    }
    var payload: [String: Any] = [
      "projectId": project.id.uuidString,
      "projectName": summary?.projectName ?? project.name,
      "todayTokens": summary?.todayTotalTokens ?? 0,
      "totalTokens": summary?.projectTotalTokens ?? 0,
      "currentSessionTokens": summary?.currentSessionTokens ?? 0,
      "currentSessionCachedInputTokens": summary?.currentSessionCachedInputTokens ?? 0,
      "projectTotalTokens": summary?.projectTotalTokens ?? 0,
      "projectCachedInputTokens": summary?.projectCachedInputTokens ?? 0,
      "todayTotalTokens": summary?.todayTotalTokens ?? 0,
      "todayCachedInputTokens": summary?.todayCachedInputTokens ?? 0,
      "requestCount": requestCount,
      "currentSessions": liveSessions,
      "todayTimeBuckets": todayTimeBuckets,
      "heatmap": heatmap,
      "toolBreakdown": toolBreakdown,
      "modelBreakdown": modelBreakdown,
    ]
    if let currentTool = summary?.currentTool { payload["currentTool"] = currentTool }
    if let currentModel = summary?.currentModel { payload["currentModel"] = currentModel }
    if let contextUsagePercent = summary?.currentContextUsagePercent {
      payload["contextUsagePercent"] = contextUsagePercent
    }
    if let updatedAt = summary?.currentSessionUpdatedAt {
      payload["updatedAt"] = ISO8601DateFormatter().string(from: updatedAt)
    }
    return payload
  }

  private func remoteProjectName(name: String?, path: String) -> String {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty == false { return trimmed }
    let fallback = URL(fileURLWithPath: path).lastPathComponent
    return fallback.isEmpty ? "Project" : fallback
  }

  func remoteCloseTerminal(sessionID: UUID) -> Bool {
    guard let workspaceIndex = workspaces.firstIndex(where: { $0.containsSession(sessionID) })
    else {
      return false
    }
    noteTerminalLoadingState(sessionID, isLoading: false)
    let projectID = workspaces[workspaceIndex].projectID
    let project = worktrees.first(where: { $0.id == projectID }).flatMap { projectForWorktree($0) }
    let shouldRebuildLastTerminal = workspaces[workspaceIndex].visibleSessionCount <= 1
    let replacementSession = shouldRebuildLastTerminal
      ? project.map { TerminalSession.make(project: $0, command: $0.defaultCommand) }
      : nil
    var updatedWorkspaces = workspaces
    updatedWorkspaces[workspaceIndex].removeSession(sessionID)
    if let replacementSession {
      updatedWorkspaces[workspaceIndex].sessions.append(replacementSession)
      _ = updatedWorkspaces[workspaceIndex].addTopSession(replacementSession.id)
      if selectedWorktreeID == projectID {
        terminalFocusRequestID = replacementSession.id
      }
    } else if selectedWorktreeID == projectID {
      terminalFocusRequestID = updatedWorkspaces[workspaceIndex].selectedSessionID
    }
    workspaces = updatedWorkspaces
    runtimeIngressService.clearLiveState(sessionID: sessionID)
    aiStatsStore.handleTerminalSessionClosed(
      sessionID: sessionID,
      project: selectedProject,
      projects: projects,
      selectedSessionID: selectedSessionID
    )
    DmuxTerminalBackend.shared.registry.release(sessionID: sessionID)
    clearTerminalRecoveryState(for: sessionID)
    persist()
    refreshAIStatsIfNeeded()
    terminalFocusRenderVersion &+= 1
    return true
  }

  private func projectForWorktree(_ worktree: ProjectWorktree) -> Project? {
    guard let rootProject = projects.first(where: { $0.id == worktree.projectID }) else {
      return nil
    }
    return Project(
      id: worktree.id,
      name: worktree.isDefault ? rootProject.name : "\(rootProject.name) · \(worktree.name)",
      path: worktree.path,
      shell: rootProject.shell,
      defaultCommand: rootProject.defaultCommand,
      badgeText: rootProject.badgeText,
      badgeSymbol: rootProject.badgeSymbol,
      badgeColorHex: rootProject.badgeColorHex,
      gitDefaultPushRemoteName: rootProject.gitDefaultPushRemoteName
    )
  }
}
