import Foundation

@MainActor
extension GitStore {
    func beginPanelOperation(allowsPreservingVisibleState: Bool = true) {
        if allowsPreservingVisibleState, panelState.gitState != nil {
            panelState.isGitLoading = false
            panelState.refreshState = .idle
        } else {
            panelState.isGitLoading = true
        }
    }

    func refresh(
        project: Project?,
        presentation: RefreshPresentation = .fullScreen,
        includesRemoteSync: Bool = true
    ) {
        guard let project else {
            panelState = .empty
            panelState.gitDiffText = String(localized: "git.empty.select_project", defaultValue: "Add or select a project to view Git status.", bundle: .module)
            return
        }

        let projectID = project.id
        let path = project.path
        let selectedIDsSnapshot = panelState.selectedGitEntryIDs
        let shouldShowBlockingLoading = presentation == .fullScreen || panelState.gitState == nil
        if shouldShowBlockingLoading {
            panelState.isGitLoading = true
        } else {
            panelState.isGitLoading = false
            panelState.refreshState = .idle
        }

        Task.detached {
            let service = GitService()
            do {
                let state = try service.repositoryState(at: path)
                await MainActor.run {
                    self.panelState.gitState = state
                    self.panelState.isGitLoading = false
                    self.panelState.refreshState = .idle
                    if state == nil {
                        self.panelState.selectedGitEntry = nil
                        self.panelState.gitDiffText = String(localized: "git.repository.not_repository", bundle: .module)
                        self.panelState.selectedGitEntryIDs.removeAll()
                        self.panelState.gitHistory = []
                        self.panelState.gitBranches = []
                        self.panelState.gitBranchUpstreams = [:]
                        self.panelState.gitRemoteBranches = []
                        self.panelState.gitRemotes = []
                        self.panelState.gitRemoteSyncState = .empty
                    } else {
                        let allEntries = (state?.staged ?? []) + (state?.changes ?? []) + (state?.untracked ?? [])
                        let validIDs = Set(allEntries.map(\.id))
                        if let selectedEntryPath = self.panelState.selectedGitEntry?.path,
                           let updatedSelectedEntry = allEntries.first(where: { $0.path == selectedEntryPath }) {
                            self.panelState.selectedGitEntry = updatedSelectedEntry
                            self.loadDiff(for: updatedSelectedEntry, project: project)
                        } else {
                            self.panelState.selectedGitEntry = nil
                            self.panelState.isGitDiffLoading = false
                            self.panelState.gitDiffText = String(localized: "git.diff.select_file", bundle: .module)
                        }
                        self.panelState.selectedGitEntryIDs = selectedIDsSnapshot.intersection(validIDs)
                        self.refreshHistory(projectPath: path, projectID: projectID)
                        self.refreshBranches(projectPath: path, projectID: projectID)
                        if includesRemoteSync {
                            self.refreshRemoteSyncState(projectPath: path, projectID: projectID)
                        }
                    }
                    self.cacheState(for: projectID)
                }
            } catch {
                await MainActor.run {
                    self.panelState.gitState = nil
                    self.panelState.gitRemoteSyncState = .empty
                    self.panelState.isGitLoading = false
                    self.panelState.refreshState = .failed(error.localizedDescription)
                    self.panelState.gitDiffText = error.localizedDescription
                    self.panelState.gitHistory = []
                    self.panelState.gitBranches = []
                    self.panelState.gitBranchUpstreams = [:]
                    self.panelState.gitRemoteBranches = []
                    self.panelState.gitRemotes = []
                    self.cacheState(for: projectID)
                }
            }
        }
    }

    func initializeRepository(project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation(allowsPreservingVisibleState: false)
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.initializeRepository(at: path)
                await MainActor.run {
                    onStatus(String(localized: "git.repository.initialized", bundle: .module))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func cloneRepository(project: Project, remoteURL: String, credential: GitCredential? = nil, onStatus: @escaping @MainActor (String) -> Void, onAuthRequired: @escaping @MainActor (@escaping (GitCredential?) -> Void) -> Void, onAuthSucceeded: @escaping @MainActor (GitCredential) -> Void) {
        beginPanelOperation(allowsPreservingVisibleState: false)
        panelState.gitOperationStatusText = String(localized: "git.clone.preparing", defaultValue: "Preparing to clone the repository...", bundle: .module)
        panelState.gitOperationProgress = 0
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.clone(remoteURL, into: path, credential: credential) { line, progressValue in
                    Task { @MainActor in
                        self.panelState.gitOperationStatusText = line
                        if let progressValue {
                            self.panelState.gitOperationProgress = progressValue
                        }
                    }
                }
                await MainActor.run {
                    if let credential {
                        onAuthSucceeded(credential)
                    }
                    self.panelState.gitOperationStatusText = nil
                    self.panelState.gitOperationProgress = nil
                    onStatus(String(localized: "git.repository.cloned", bundle: .module))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    if case GitServiceError.authenticationRequired = error,
                       credential == nil {
                        onAuthRequired { credential in
                            guard let credential else {
                                self.panelState.isGitLoading = false
                                self.panelState.gitOperationStatusText = String(localized: "git.auth.cancelled", bundle: .module)
                                self.panelState.gitOperationProgress = nil
                                onStatus(String(localized: "git.auth.cancelled", bundle: .module))
                                return
                            }
                            self.cloneRepository(project: project, remoteURL: remoteURL, credential: credential, onStatus: onStatus, onAuthRequired: onAuthRequired, onAuthSucceeded: onAuthSucceeded)
                        }
                        return
                    }
                    self.panelState.isGitLoading = false
                    self.panelState.gitOperationStatusText = error.localizedDescription
                    self.panelState.gitOperationProgress = nil
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func restoreCachedState(for projectID: UUID) {
        guard let entry = cachedPanels.value(for: projectID) else {
            panelState.refreshState = .refreshing
            panelState.selectedGitEntry = nil
            panelState.selectedGitCommitHash = nil
            panelState.gitDiffText = String(localized: "git.diff.select_file", bundle: .module)
            panelState.selectedGitEntryIDs.removeAll()
            panelState.gitHistory = []
            panelState.gitBranches = []
            panelState.gitRemoteBranches = []
            panelState.gitRemotes = []
            panelState.gitRemoteSyncState = .empty
            return
        }

        panelState = entry.state
        panelState.refreshState = .showingCached
    }

    func startRemoteSyncPolling(selectedProject: @escaping @MainActor () -> Project?, isEnabled: @escaping @MainActor () -> Bool) {
        selectedProjectProvider = selectedProject
        remoteSyncEnabledProvider = isEnabled
        remoteSyncTimer?.invalidate()
        remoteSyncTimer = Timer.scheduledTimer(withTimeInterval: remoteSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, isEnabled(), self.panelState.activeGitRemoteOperation == nil, let project = selectedProject() else {
                    return
                }
                self.refreshRemoteSyncState(projectPath: project.path, projectID: project.id)
            }
        }
    }

    func configureRemoteSyncInterval(_ interval: TimeInterval) {
        remoteSyncInterval = max(15, interval)
        if let selectedProjectProvider, let remoteSyncEnabledProvider {
            startRemoteSyncPolling(selectedProject: selectedProjectProvider, isEnabled: remoteSyncEnabledProvider)
        }
    }

    func stopRemoteSyncPolling() {
        remoteSyncTimer?.invalidate()
        remoteSyncTimer = nil
    }

    func startStatusAutoRefresh(selectedProject: @escaping @MainActor () -> Project?, isEnabled: @escaping @MainActor () -> Bool) {
        statusAutoRefreshSelectedProjectProvider = selectedProject
        statusAutoRefreshEnabledProvider = isEnabled
        updateStatusAutoRefreshWatcher()
    }

    func stopStatusAutoRefresh() {
        pendingAutomaticRefreshTask?.cancel()
        pendingAutomaticRefreshTask = nil
        repositoryWatcher?.invalidate()
        repositoryWatcher = nil
        watchedRepositoryProjectID = nil
        watchedRepositoryPath = nil
        isAutomaticRefreshInFlight = false
    }

    func updateStatusAutoRefreshWatcher() {
        guard let selectedProjectProvider = statusAutoRefreshSelectedProjectProvider,
              let enabledProvider = statusAutoRefreshEnabledProvider else {
            stopStatusAutoRefresh()
            return
        }
        guard enabledProvider(), let project = selectedProjectProvider() else {
            stopStatusAutoRefresh()
            return
        }

        let normalizedPath = URL(fileURLWithPath: project.path).standardizedFileURL.path
        guard watchedRepositoryProjectID != project.id
                || watchedRepositoryPath != normalizedPath
                || repositoryWatcher == nil else {
            return
        }

        repositoryWatcher?.invalidate()
        repositoryWatcher = GitRepositoryWatcher(repositoryPath: normalizedPath) { [weak self] _ in
            self?.scheduleAutomaticRefresh()
        }
        watchedRepositoryProjectID = project.id
        watchedRepositoryPath = normalizedPath
    }

    func scheduleAutomaticRefresh() {
        guard let selectedProjectProvider = statusAutoRefreshSelectedProjectProvider,
              let enabledProvider = statusAutoRefreshEnabledProvider else {
            return
        }

        pendingAutomaticRefreshTask?.cancel()
        pendingAutomaticRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self else {
                return
            }
            self.pendingAutomaticRefreshTask = nil

            guard enabledProvider(),
                  let project = selectedProjectProvider() else {
                return
            }

            self.refreshFromAutomaticSource(project: project)
        }
    }

    func refreshFromAutomaticSource(project: Project) {
        guard panelState.activeGitRemoteOperation == nil,
              isAutomaticRefreshInFlight == false else {
            return
        }

        isAutomaticRefreshInFlight = true
        refresh(
            project: project,
            presentation: .preserveVisibleState,
            includesRemoteSync: false
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.isAutomaticRefreshInFlight = false
        }
    }

    func cacheState(for projectID: UUID) {
        cachedPanels.set(CachedGitPanelEntry(projectID: projectID, state: panelState, updatedAt: Date()), for: projectID)
    }

    func refreshHistory(projectPath: String, projectID: UUID) {
        Task.detached {
            let service = GitService()
            do {
                let history = try service.history(at: projectPath)
                await MainActor.run {
                    self.panelState.gitHistory = history
                    self.cacheState(for: projectID)
                }
            } catch {
                await MainActor.run {
                    self.panelState.gitHistory = []
                    self.cacheState(for: projectID)
                }
            }
        }
    }

    func refreshBranches(projectPath: String, projectID: UUID) {
        Task.detached {
            let service = GitService()
            do {
                let branches = try service.localBranches(at: projectPath)
                let branchUpstreams = try service.localBranchUpstreams(at: projectPath)
                let remoteBranches = try service.remoteBranches(at: projectPath)
                let remotes = try service.remotes(at: projectPath)
                await MainActor.run {
                    self.panelState.gitBranches = branches
                    self.panelState.gitBranchUpstreams = branchUpstreams
                    self.panelState.gitRemoteBranches = remoteBranches
                    self.panelState.gitRemotes = remotes
                    self.cacheState(for: projectID)
                }
            } catch {
                await MainActor.run {
                    self.panelState.gitBranches = []
                    self.panelState.gitBranchUpstreams = [:]
                    self.panelState.gitRemoteBranches = []
                    self.panelState.gitRemotes = []
                    self.cacheState(for: projectID)
                }
            }
        }
    }

    func refreshRemoteSyncState(projectPath: String, projectID: UUID) {
        Task.detached {
            let service = GitService()
            do {
                try service.fetch(at: projectPath)
                let syncState = try service.remoteSyncState(at: projectPath)
                let remotes = try service.remotes(at: projectPath)
                await MainActor.run {
                    self.panelState.gitRemoteSyncState = syncState
                    self.panelState.gitRemotes = remotes
                    self.cacheState(for: projectID)
                }
            } catch {
            }
        }
    }
}
