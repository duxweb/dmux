import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

enum GitRemoteAction {
    case fetch
    case pull
    case push
    case forcePush
    case sync
}

enum GitRemoteOperation: Equatable {
    case fetch
    case pull
    case push
    case forcePush
}

enum RightPanelKind: String, Codable, Equatable {
    case git
    case aiStats
}

@MainActor
@Observable
final class AppModel {
    struct TerminalRecoveryIssue: Equatable {
        var message: String
        var detail: String
    }

    var projects: [Project]
    var workspaces: [ProjectWorkspace]
    var selectedProjectID: UUID? {
        didSet {
            guard oldValue != selectedProjectID else { return }
            debugLog.log(
                "project-selection",
                "change source=\(selectedProjectIDChangeSource) old=\(oldValue?.uuidString ?? "nil") new=\(selectedProjectID?.uuidString ?? "nil")"
            )
            selectedProjectIDChangeSource = "unspecified"
        }
    }
    var appSettings: AppSettings
    var activeTerminalBackgroundPreset: AppTerminalBackgroundPreset
    var activeBackgroundColorPreset: AppBackgroundColorPreset
    var rightPanel: RightPanelKind?
    var commitMessage = ""
    var statusMessage = ""
    var isSidebarExpanded = false
    var activityByProjectID: [UUID: ProjectActivityPhase] = [:]
    var activityRenderVersion: UInt64 = 0
    var rightPanelWidth: CGFloat = 360
    var isGeneratingCommitMessage = false
    var terminalFocusRequestID: UUID?
    var terminalFocusRenderVersion: UInt64 = 0
    let aiSessionStore = AISessionStore.shared
    let aiStatsStore = AIStatsStore()
    let petStore = PetStore.shared
    let gitStore = GitStore()
    let performanceMonitor = AppPerformanceMonitorStore()

    private let persistenceService: PersistenceService
    private let gitService = GitService()
    private let gitCredentialStore = GitCredentialStore()
    private let activityService = ProjectActivityService()
    let diagnosticsExportService = AppDiagnosticsExportService()
    private let toolPermissionSettingsService = AIToolPermissionSettingsService()
    private let appUpdaterService = AppUpdaterService(isEnabled: AppUpdaterService.isSupportedConfiguration)
    private let runtimeBridgeService = AIRuntimeBridgeService()
    let runtimeIngressService = AIRuntimeIngressService.shared
    private let runtimePollingService = AIRuntimePollingService.shared
    let toolDriverFactory = AIToolDriverFactory.shared
    let debugLog = AppDebugLog.shared
    var selectedProjectIDChangeSource = "init"
    private var activityStatusWatcher: DispatchSourceFileSystemObject?
    private var appActivationObservers: [NSObjectProtocol] = []
    private var terminalFocusObserver: NSObjectProtocol?
    private var terminalInterruptObserver: NSObjectProtocol?
    private var runtimeBridgeObserver: NSObjectProtocol?
    private var runtimeActivityObserver: NSObjectProtocol?
    private var pendingActivityRefreshTask: Task<Void, Never>?
    private var pendingActivityRefreshShouldNotify = false
    private var pendingActivityRefreshShouldRefreshAIStats = false
    private var pendingActivityRefreshRequiresStatusReload = false
    private var cachedActivityPayloadByProjectID: [UUID: ProjectActivityPayload] = [:]
    private var lastCompletionTokenByProjectID: [UUID: String] = [:]
    private var clearedCompletionTokenByProjectID: [UUID: String] = [:]
    private var lastWaitingInputTokenByProjectID: [UUID: String] = [:]
    private var isSystemUIReady = false
    private var isTerminalStartupUnlocked = false
    private var hasLoggedRootViewAppearance = false
    private var lastWorkspaceAppearanceToken: String?
    private var pendingTerminalStartupUnlockTask: Task<Void, Never>?
    private var terminalRecoveryIssueBySessionID: [UUID: TerminalRecoveryIssue] = [:]
    private var terminalRecoveryRetryTokenBySessionID: [UUID: Int] = [:]
    private var pendingStartupRecoveryDialog: ConfirmDialogState?
    private var hasPresentedStartupRecoveryDialog = false
    private var hasScheduledLaunchUpdateCheck = false
    var detachedTerminalPlacementBySessionID: [UUID: DetachedTerminalPlacement] = [:]

    init(snapshot: AppSnapshot?, persistenceService: PersistenceService, startupIssues: [PersistenceLoadIssue] = []) {
        self.persistenceService = persistenceService
        debugLog.reset()

        let resolvedSettings: AppSettings
        if let snapshot {
            self.projects = snapshot.projects
            self.workspaces = snapshot.workspaces
            self.selectedProjectID = snapshot.selectedProjectID ?? snapshot.projects.first?.id
            resolvedSettings = snapshot.appSettings ?? AppSettings()
            self.appSettings = resolvedSettings
        } else {
            self.projects = []
            self.workspaces = []
            self.selectedProjectID = nil
            resolvedSettings = AppSettings()
            self.appSettings = resolvedSettings
        }
        self.activeTerminalBackgroundPreset = resolvedSettings.terminalBackgroundPreset
        self.activeBackgroundColorPreset = resolvedSettings.backgroundColorPreset

        DmuxTerminalBackend.shared.configure(using: appSettings)

        refreshGitState()
        resetActivityState()
        activityService.clearAllStatuses()
        runtimeIngressService.resetEphemeralState()
        runtimeBridgeService.prepareManagedRuntimeSupportIfNeeded()
        runtimePollingService.start()
        refreshProjectActivity(sendNotifications: false)
        activityService.requestNotificationPermission()
        observeApplicationActivation()
        observeTerminalFocusChanges()
        startActivityWatchers()
        debugLog.log("app", "launch selectedProject=\(selectedProject?.name ?? "nil")")
        aiStatsStore.configureIntervals(
            automatic: appSettings.aiAutoRefreshInterval,
            background: appSettings.aiBackgroundRefreshInterval
        )
        aiStatsStore.startTimers(
            isPanelVisible: { self.rightPanel == .aiStats },
            selectedProject: { self.selectedProject },
            selectedSessionID: { self.selectedSessionID },
            projects: { self.projects }
        )
        gitStore.configureRemoteSyncInterval(appSettings.gitAutoRefreshInterval)
        gitStore.startRemoteSyncPolling(
            selectedProject: { self.selectedProject },
            isEnabled: { NSApplication.shared.isActive && self.rightPanel == .git }
        )
        updateGitRemoteSyncPolling()
        performanceMonitor.setContextProvider { [weak self] in
            self?.performanceMonitorContextSnapshot() ?? .empty
        }
        performanceMonitor.setApplicationActive(NSApplication.shared.isActive)
        performanceMonitor.configure(
            isEnabled: appSettings.developer.showsPerformanceMonitor,
            sampleInterval: appSettings.developer.performanceMonitorSamplingInterval
        )
        toolPermissionSettingsService.sync(appSettings.toolPermissions)

        pendingStartupRecoveryDialog = startupRecoveryDialog(for: startupIssues)
        if pendingStartupRecoveryDialog != nil {
            statusMessage = String(localized: "startup.recovery.status", defaultValue: "Recovered invalid saved app data.", bundle: .module)
        }

        appUpdaterService.onCanCheckForUpdatesChanged = { [weak self] canCheck in
            guard let self else {
                return
            }
            if canCheck {
                self.isCheckingForUpdates = false
            }
        }

        Task { @MainActor in
            self.isSystemUIReady = true
            self.applyThemeMode()
            self.applyAppIcon()
            self.updateDockBadge()
        }
    }

    private func resetActivityState() {
        aiSessionStore.reset()
        activityByProjectID = [:]
        activityRenderVersion = 0
        cachedActivityPayloadByProjectID.removeAll()
        lastCompletionTokenByProjectID.removeAll()
        clearedCompletionTokenByProjectID.removeAll()
        lastWaitingInputTokenByProjectID.removeAll()
    }

    var allowsDeferredTerminalStartup: Bool {
        isTerminalStartupUnlocked
    }

    static func bootstrap() -> AppModel {
        let persistenceService = PersistenceService()
        let loadResult = persistenceService.loadWithRecovery()
        return AppModel(
            snapshot: loadResult.snapshot,
            persistenceService: persistenceService,
            startupIssues: loadResult.issues
        )
    }

    var selectedProject: Project? {
        guard let selectedProjectID else {
            return nil
        }

        return projects.first(where: { $0.id == selectedProjectID })
    }

    func terminalSession(for sessionID: UUID) -> TerminalSession? {
        workspaces.lazy.compactMap { $0.session(for: sessionID) }.first
    }

    func isDetachedTerminal(_ sessionID: UUID) -> Bool {
        detachedTerminalPlacementBySessionID[sessionID] != nil
    }

    func presentStartupRecoveryIfNeeded() {
        guard hasPresentedStartupRecoveryDialog == false,
              let dialog = pendingStartupRecoveryDialog,
              let parentWindow = presentationWindow() else {
            return
        }

        hasPresentedStartupRecoveryDialog = true
        pendingStartupRecoveryDialog = nil
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { _ in }
    }

    func noteRootViewAppeared() {
        guard hasLoggedRootViewAppearance == false else {
            return
        }
        hasLoggedRootViewAppearance = true
        debugLog.log("startup-ui", "root-view appeared selectedProject=\(selectedProject?.name ?? "nil")")
        unlockDeferredTerminalStartupAfterInitialPresentation()
        scheduleLaunchUpdateCheckIfNeeded()
    }

    func noteWorkspaceViewAppeared() {
        let token: String
        if let workspace = selectedWorkspace {
            token = "project:\(workspace.projectID.uuidString):top=\(workspace.topSessionIDs.count):bottom=\(workspace.bottomTabSessionIDs.count):selected=\(workspace.selectedSessionID.uuidString)"
        } else {
            token = "empty"
        }

        guard lastWorkspaceAppearanceToken != token else {
            return
        }
        lastWorkspaceAppearanceToken = token

        if let workspace = selectedWorkspace {
            debugLog.log(
                "startup-ui",
                "workspace-view project=\(workspace.projectID.uuidString) topSessions=\(workspace.topSessionIDs.count) bottomTabs=\(workspace.bottomTabSessionIDs.count) selectedSession=\(workspace.selectedSessionID.uuidString)"
            )
        } else {
            debugLog.log("startup-ui", "workspace-view empty")
        }
    }

    func terminalRecoveryIssue(for sessionID: UUID) -> TerminalRecoveryIssue? {
        terminalRecoveryIssueBySessionID[sessionID]
    }

    func terminalRecoveryRetryToken(for sessionID: UUID) -> Int {
        terminalRecoveryRetryTokenBySessionID[sessionID] ?? 0
    }

    func noteTerminalStartupFailure(_ sessionID: UUID, detail: String) {
        let message = String(
            localized: "terminal.recovery.failed",
            defaultValue: "Terminal recovery failed. Showing the project shell instead.",
            bundle: .module
        )
        let issue = TerminalRecoveryIssue(message: message, detail: detail)
        guard terminalRecoveryIssueBySessionID[sessionID] != issue else {
            return
        }

        terminalRecoveryIssueBySessionID[sessionID] = issue
        if let context = terminalRecoveryContext(for: sessionID) {
            debugLog.log(
                "terminal-recovery",
                "failed session=\(sessionID.uuidString) project=\(context.projectID.uuidString) title=\(context.title) detail=\(detail)"
            )
        } else {
            debugLog.log(
                "terminal-recovery",
                "failed session=\(sessionID.uuidString) detail=\(detail)"
            )
        }
        debugLog.log(
            "terminal-lifecycle",
            "release-request session=\(sessionID.uuidString) reason=startup-failure"
        )
        DmuxTerminalBackend.shared.registry.release(sessionID: sessionID)

        if selectedSessionID == sessionID {
            statusMessage = message
        }
    }

    func noteTerminalStartupSucceeded(_ sessionID: UUID) {
        guard terminalRecoveryIssueBySessionID.removeValue(forKey: sessionID) != nil else {
            return
        }
        debugLog.log("terminal-recovery", "recovered session=\(sessionID.uuidString)")
    }

    func retryTerminalRecovery(_ sessionID: UUID) {
        terminalRecoveryIssueBySessionID[sessionID] = nil
        terminalRecoveryRetryTokenBySessionID[sessionID, default: 0] += 1
        debugLog.log(
            "terminal-lifecycle",
            "release-request session=\(sessionID.uuidString) reason=recovery-retry token=\(terminalRecoveryRetryTokenBySessionID[sessionID] ?? 0)"
        )
        DmuxTerminalBackend.shared.registry.release(sessionID: sessionID)
        terminalFocusRequestID = sessionID
        debugLog.log(
            "terminal-recovery",
            "retry session=\(sessionID.uuidString) token=\(terminalRecoveryRetryTokenBySessionID[sessionID] ?? 0)"
        )
        statusMessage = String(localized: "terminal.recovery.retrying", defaultValue: "Retrying terminal recovery.", bundle: .module)
    }

    var selectedWorkspace: ProjectWorkspace? {
        guard let selectedProjectID else {
            return nil
        }

        return workspaces.first(where: { $0.projectID == selectedProjectID })
    }

    var selectedSessionID: UUID? {
        selectedWorkspace?.selectedSessionID
    }

    var displayedFocusedTerminalSessionID: UUID? {
        Self.resolveDisplayedFocusedTerminalSessionID(
            focusRequestID: terminalFocusRequestID,
            registryFocusedSessionID: DmuxTerminalBackend.shared.registry.focusedSessionID(),
            selectedSessionID: selectedSessionID
        )
    }

    static func resolveDisplayedFocusedTerminalSessionID(
        focusRequestID: UUID?,
        registryFocusedSessionID: UUID?,
        selectedSessionID: UUID?
    ) -> UUID? {
        focusRequestID ?? registryFocusedSessionID ?? selectedSessionID
    }

    static func shouldRefreshSelectionFocus(
        requestedSessionID: UUID,
        selectedSessionID: UUID?,
        pendingFocusRequestID: UUID?,
        registryFocusedSessionID: UUID?
    ) -> Bool {
        if selectedSessionID != requestedSessionID {
            return true
        }
        if let pendingFocusRequestID {
            return pendingFocusRequestID != requestedSessionID
        }
        return registryFocusedSessionID != requestedSessionID
    }

    static func shouldRefreshBottomTabSelection(
        requestedSessionID: UUID,
        selectedSessionID: UUID?,
        selectedBottomTabSessionID: UUID?,
        pendingFocusRequestID: UUID?,
        registryFocusedSessionID: UUID?
    ) -> Bool {
        if selectedBottomTabSessionID != requestedSessionID {
            return true
        }
        return shouldRefreshSelectionFocus(
            requestedSessionID: requestedSessionID,
            selectedSessionID: selectedSessionID,
            pendingFocusRequestID: pendingFocusRequestID,
            registryFocusedSessionID: registryFocusedSessionID
        )
    }

    private func unlockDeferredTerminalStartupAfterInitialPresentation() {
        guard isTerminalStartupUnlocked == false else {
            return
        }
        pendingTerminalStartupUnlockTask?.cancel()
        pendingTerminalStartupUnlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, !Task.isCancelled else {
                return
            }
            self.isTerminalStartupUnlocked = true
            self.pendingTerminalStartupUnlockTask = nil
            self.debugLog.log("startup-ui", "terminal-startup unlocked")
            self.refreshAIStatsIfNeeded()
        }
    }

    func clearTerminalRecoveryState(for sessionID: UUID) {
        terminalRecoveryIssueBySessionID[sessionID] = nil
        terminalRecoveryRetryTokenBySessionID[sessionID] = nil
    }

    private func terminalRecoveryContext(for sessionID: UUID) -> (projectID: UUID, title: String)? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == sessionID }) {
                return (workspace.projectID, session.title)
            }
        }
        return nil
    }

    var aiStatsState: AIStatsPanelState {
        aiStatsStore.state
    }

    var displayLanguage: AppLanguage {
        AppLanguageBootstrap.languageAtLaunch.resolved
    }

    var aiPanelRefreshState: PanelRefreshState {
        aiStatsStore.refreshState
    }

    var terminalBackgroundPreset: AppTerminalBackgroundPreset {
        activeTerminalBackgroundPreset
    }

    var backgroundColorPreset: AppBackgroundColorPreset {
        activeBackgroundColorPreset
    }

    var automaticTerminalAppearance: AppEffectiveTerminalAppearance {
        GhosttyEmbeddedConfig.resolvedAutomaticTerminalAppearance(
            prefersDarkAppearance: systemPrefersDarkAppearance
        )
    }

    var terminalAppearance: AppEffectiveTerminalAppearance {
        terminalBackgroundPreset.effectiveAppearance(
            backgroundColorPreset: backgroundColorPreset,
            automaticAppearance: automaticTerminalAppearance
        )
    }

    var effectiveThemeMode: AppThemeMode {
        terminalAppearance.isLight ? .light : .dark
    }

    var terminalChromeColor: Color {
        Color(nsColor: terminalAppearance.backgroundColor)
    }

    var windowGlassTintColor: Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return self.terminalAppearance.windowGlassTintColor(forDarkAppearance: isDark)
            }
        )
    }

    var terminalDividerColor: Color {
        Color(nsColor: terminalAppearance.dividerColor)
    }

    var terminalDividerNSColor: NSColor {
        terminalAppearance.dividerColor
    }

    var terminalTextColor: Color {
        Color(nsColor: terminalAppearance.foregroundColor)
    }

    var terminalMutedTextColor: Color {
        Color(nsColor: terminalAppearance.mutedForegroundColor)
    }

    var terminalUsesLightBackground: Bool {
        terminalAppearance.isLight
    }

    var terminalInactiveDimColor: NSColor {
        terminalAppearance.inactiveDimColor
    }

    private var systemPrefersDarkAppearance: Bool {
        let appearance = NSApplication.shared.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var gitPanelState: GitPanelState {
        gitStore.panelState
    }

    var gitState: GitRepositoryState? {
        get { gitStore.panelState.gitState }
        set { gitStore.panelState.gitState = newValue }
    }

    var selectedGitEntry: GitFileEntry? {
        get { gitStore.panelState.selectedGitEntry }
        set { gitStore.panelState.selectedGitEntry = newValue }
    }

    var selectedGitEntryIDs: Set<String> {
        get { gitStore.panelState.selectedGitEntryIDs }
        set { gitStore.panelState.selectedGitEntryIDs = newValue }
    }

    var gitHistory: [GitCommitEntry] {
        get { gitStore.panelState.gitHistory }
        set { gitStore.panelState.gitHistory = newValue }
    }

    var selectedGitCommitHash: String? {
        get { gitStore.panelState.selectedGitCommitHash }
        set { gitStore.panelState.selectedGitCommitHash = newValue }
    }

    var gitDiffText: String {
        get { gitStore.panelState.gitDiffText }
        set { gitStore.panelState.gitDiffText = newValue }
    }

    var isGitLoading: Bool {
        get { gitStore.panelState.isGitLoading }
        set { gitStore.panelState.isGitLoading = newValue }
    }

    var isCheckingForUpdates = false

    var isGitDiffLoading: Bool {
        get { gitStore.panelState.isGitDiffLoading }
        set { gitStore.panelState.isGitDiffLoading = newValue }
    }

    var gitSelectionAnchorID: String? {
        get { gitStore.panelState.gitSelectionAnchorID }
        set { gitStore.panelState.gitSelectionAnchorID = newValue }
    }

    var gitBranches: [String] {
        get { gitStore.panelState.gitBranches }
        set { gitStore.panelState.gitBranches = newValue }
    }

    var gitBranchUpstreams: [String: String] {
        get { gitStore.panelState.gitBranchUpstreams }
        set { gitStore.panelState.gitBranchUpstreams = newValue }
    }

    var gitRemoteBranches: [String] {
        get { gitStore.panelState.gitRemoteBranches }
        set { gitStore.panelState.gitRemoteBranches = newValue }
    }

    var gitRemotes: [GitRemoteEntry] {
        get { gitStore.panelState.gitRemotes }
        set { gitStore.panelState.gitRemotes = newValue }
    }

    var gitRemoteSyncState: GitRemoteSyncState {
        get { gitStore.panelState.gitRemoteSyncState }
        set { gitStore.panelState.gitRemoteSyncState = newValue }
    }

    var activeGitRemoteOperation: GitRemoteOperation? {
        get { gitStore.panelState.activeGitRemoteOperation }
        set { gitStore.panelState.activeGitRemoteOperation = newValue }
    }

    func activityPhase(for projectID: UUID) -> ProjectActivityPhase {
        let runtimePhase = aiSessionStore.projectPhase(projectID: projectID)
        if runtimePhase != .idle {
            logActivityPhaseResolution(projectID: projectID, source: "runtime", phase: runtimePhase)
            return runtimePhase
        }
        let cachedPhase = cachedActivityPhase(for: projectID)
        if cachedPhase != .idle {
            logActivityPhaseResolution(projectID: projectID, source: "cached", phase: cachedPhase)
            return cachedPhase
        }
        logActivityPhaseResolution(projectID: projectID, source: "default", phase: .idle)
        return .idle
    }

    func isGitEntrySelected(_ entry: GitFileEntry) -> Bool {
        gitStore.isEntrySelected(entry)
    }

    func toggleGitEntrySelection(_ entry: GitFileEntry) {
        gitStore.toggleEntrySelection(entry)
    }

    func selectGitEntry(_ entry: GitFileEntry, extendingRange: Bool) {
        gitStore.selectEntry(entry, in: gitState, extendingRange: extendingRange)
    }

    func prepareGitEntryContextMenu(_ entry: GitFileEntry) {
        if selectedGitEntryIDs.contains(entry.id) {
            gitStore.prepareEntryContextMenu(entry)
            loadDiff(for: entry)
            return
        }

        selectGitEntry(entry, extendingRange: false)
        loadDiff(for: entry)
    }

    func prepareGitCommitContextMenu(_ commit: GitCommitEntry) {
        gitStore.selectCommit(commit)
    }

    var selectedGitEntriesForContextMenu: [GitFileEntry] {
        guard let gitState else { return [] }
        let all = flatGitEntries(from: gitState)
        return all.filter { selectedGitEntryIDs.contains($0.id) }
    }

    func copyGitPaths(_ entries: [GitFileEntry]) {
        let text = entries.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = entries.count > 1 ? String(localized: "git.files.copy_selected_paths.success", defaultValue: "Copied selected file paths.", bundle: .module) : String(localized: "git.files.copy_path.success", defaultValue: "Copied file path.", bundle: .module)
    }

    func addGitEntriesToIgnore(_ entries: [GitFileEntry]) {
        guard let project = selectedProject else { return }
        let paths = Array(Set(entries.map(\.path))).sorted()
        guard !paths.isEmpty else { return }

        let repositoryPath = project.path
        isGitLoading = true

        Task.detached {
            let service = GitService()
            do {
                try service.appendToGitignore(paths, at: repositoryPath)
                await MainActor.run {
                    self.statusMessage = paths.count > 1 ? String(localized: "git.ignore.added", defaultValue: "Added to .gitignore.", bundle: .module) : String(localized: "git.ignore.added", defaultValue: "Added to .gitignore.", bundle: .module)
                    self.refreshGitState()
                }
            } catch {
                await MainActor.run {
                    self.isGitLoading = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    func revealGitEntriesInFinder(_ entries: [GitFileEntry]) {
        guard let project = selectedProject else { return }
        let urls = entries.map { URL(fileURLWithPath: project.path).appendingPathComponent($0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func mergeBranchIntoCurrent(_ branch: String) {
        guard let project = selectedProject else { return }
        let currentBranch = gitState?.branch ?? String(localized: "git.branch.current_label", defaultValue: "Current Branch", bundle: .module)
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "git.branch.merge.title", defaultValue: "Merge Branch", bundle: .module),
            message: String(
                format: String(localized: "git.branch.merge.message_format", defaultValue: "Merge %@ into %@.", bundle: .module),
                branch,
                currentBranch
            ),
            icon: "arrow.merge",
            iconColor: AppTheme.focus,
            primaryTitle: String(localized: "common.merge", defaultValue: "Merge", bundle: .module),
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            let path = project.path
            self.isGitLoading = true

            Task.detached {
                let service = GitService()
                do {
                    try service.merge(branch: branch, intoCurrentBranchAt: path)
                    await MainActor.run {
                        self.statusMessage = String(
                            format: String(localized: "git.branch.merge.success_format", defaultValue: "Merged branch %@.", bundle: .module),
                            branch
                        )
                        self.refreshGitState()
                    }
                } catch {
                    await MainActor.run {
                        self.isGitLoading = false
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func syncMainBranchIntoCurrent() {
        let mainBranch = gitBranches.contains("main") ? "main" : (gitBranches.contains("master") ? "master" : nil)
        guard let mainBranch else {
            statusMessage = String(localized: "git.main_branch.not_found", defaultValue: "Main branch not found.", bundle: .module)
            return
        }

        if gitState?.branch == mainBranch {
            statusMessage = String(localized: "git.main_branch.already_on", defaultValue: "Already on the main branch.", bundle: .module)
            return
        }

        let currentBranch = gitState?.branch ?? String(localized: "git.branch.current_label", defaultValue: "Current Branch", bundle: .module)
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = ConfirmDialogState(
            title: String(localized: "git.main_branch.sync.title", defaultValue: "Sync Main Branch", bundle: .module),
            message: String(
                format: String(localized: "git.main_branch.sync.message_format", defaultValue: "Merge the latest changes from %@ into %@.", bundle: .module),
                mainBranch,
                currentBranch
            ),
            icon: "arrow.triangle.merge",
            iconColor: AppTheme.focus,
            primaryTitle: String(localized: "common.sync", defaultValue: "Sync", bundle: .module),
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            self.mergeBranchIntoCurrent(mainBranch)
        }
    }

    func refreshGitState(
        presentation: GitStore.RefreshPresentation = .fullScreen,
        includesRemoteSync: Bool = true
    ) {
        gitStore.refresh(
            project: selectedProject,
            presentation: presentation,
            includesRemoteSync: includesRemoteSync
        )
    }

    func initializeGitRepository() {
        guard let project = selectedProject else { return }
        gitStore.initializeRepository(project: project) { self.statusMessage = $0 }
    }

    func cloneGitRepository() {
        guard let project = selectedProject else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = GitInputDialogState(
            kind: .cloneRepository,
            title: String(localized: "git.empty.clone_remote_repository", defaultValue: "Clone Remote Repository", bundle: .module),
            message: String(localized: "git.clone.message", defaultValue: "Enter a remote repository URL to clone it into the current project directory.", bundle: .module),
            placeholder: "https://github.com/foo/bar.git",
            confirmTitle: String(localized: "git.clone.start", defaultValue: "Start Clone", bundle: .module),
            value: "",
            isMultiline: false
        )
        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] value in
            guard let self, let value else { return }
            let remoteURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteURL.isEmpty else {
                self.statusMessage = String(localized: "git.remote.url_required", defaultValue: "Please enter a remote repository URL.", bundle: .module)
                return
            }

            let savedCredential = self.gitCredentialStore.credential(for: remoteURL)
            self.gitStore.cloneRepository(project: project, remoteURL: remoteURL, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
                self.promptForGitCredential(completion: completion)
            }, onAuthSucceeded: { credential in
                self.gitCredentialStore.save(credential, for: remoteURL)
            })
        }
    }

    func restoreCachedGitPanelIfAvailable(for projectID: UUID) {
        gitStore.restoreCachedState(for: projectID)
    }

    func checkoutGitBranch(_ branch: String) {
        guard let project = selectedProject else { return }
        gitStore.checkoutBranch(branch, project: project) { self.statusMessage = $0 }
    }

    func checkoutRemoteGitBranch(_ remoteBranch: String) {
        guard let project = selectedProject else { return }
        gitStore.checkoutRemoteBranch(remoteBranch, project: project) { self.statusMessage = $0 }
    }

    func selectGitCommit(_ commit: GitCommitEntry) {
        gitStore.selectCommit(commit)
    }

    func copyGitCommitHash(_ commit: GitCommitEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
        statusMessage = String(localized: "git.commit.hash.copied", defaultValue: "Copied commit hash.", bundle: .module)
    }

    func checkoutGitCommit(_ commit: GitCommitEntry) {
        guard let project = selectedProject else { return }
        gitStore.checkoutCommit(commit, project: project) { self.statusMessage = $0 }
    }

    func revertGitCommit(_ commit: GitCommitEntry) {
        guard let project = selectedProject else { return }
        gitStore.revertCommit(commit, project: project) { self.statusMessage = $0 }
    }

    func createBranch(from commit: GitCommitEntry) {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = GitInputDialogState(
            kind: .createBranchFromCommit(commit.hash),
            title: String(localized: "git.branch.create_from_commit.title", defaultValue: "Create Branch from Commit", bundle: .module),
            message: String(localized: "git.branch.new.message", defaultValue: "Enter a new branch name.", bundle: .module),
            placeholder: "feature/from-commit",
            confirmTitle: String(localized: "common.create", defaultValue: "Create", bundle: .module),
            value: "",
            isMultiline: false
        )

        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] branchName in
            guard let self, let branchName else { return }
            self.createGitBranch(named: branchName, from: commit.hash)
        }
    }

    func restoreGitCommit(_ commit: GitCommitEntry, forceRemote: Bool) {
        guard let project = selectedProject else { return }

        let dialog = ConfirmDialogState(
            title: forceRemote ? String(localized: "git.history.restore_remote", defaultValue: "Restore This Revision Remotely", bundle: .module) : String(localized: "git.history.restore_local", defaultValue: "Restore This Revision Locally", bundle: .module),
            message: forceRemote
                ? String(localized: "git.history.restore_remote.message", defaultValue: "Reset the current branch to this revision and overwrite the remote branch.", bundle: .module)
                : String(localized: "git.history.restore_local.message", defaultValue: "Reset the current branch to this revision locally only.", bundle: .module),
            icon: forceRemote ? "arrow.uturn.backward.circle.fill" : "clock.arrow.circlepath",
            iconColor: AppTheme.warning,
            primaryTitle: forceRemote ? String(localized: "git.history.restore_remote.action", defaultValue: "Remote Restore", bundle: .module) : String(localized: "git.history.restore_local.action", defaultValue: "Local Restore", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            self.gitStore.restoreCommit(commit, forceRemote: forceRemote, project: project) { self.statusMessage = $0 }
        }
    }

    func pullGitBranch() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.pull, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func fetchGitBranch() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.fetch, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func refreshRemoteBranches() {
        guard let project = selectedProject else { return }
        gitStore.refreshRemoteBranches(project: project) { self.statusMessage = $0 }
    }

    func addGitRemote() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        guard let project = selectedProject else { return }

        let nameDialog = GitInputDialogState(
            kind: .cloneRepository,
            title: String(localized: "git.remote.add", defaultValue: "Add Remote", bundle: .module),
            message: String(localized: "git.remote.add.name_message", defaultValue: "Enter the remote name first, such as origin or upstream.", bundle: .module),
            placeholder: String(localized: "git.remote.name", defaultValue: "Remote Name", bundle: .module),
            confirmTitle: String(localized: "common.next", defaultValue: "Next", bundle: .module),
            value: "",
            isMultiline: false
        )

        GitInputPanelPresenter.present(dialog: nameDialog, parentWindow: parentWindow) { [weak self] nameValue in
            guard let self else { return }
            let name = nameValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }

            let urlDialog = GitInputDialogState(
                kind: .cloneRepository,
                title: String(localized: "git.remote.add", defaultValue: "Add Remote", bundle: .module),
                message: String(localized: "git.remote.add.url_message", defaultValue: "Enter the remote URL.", bundle: .module),
                placeholder: "https://github.com/org/repo.git",
                confirmTitle: String(localized: "common.add", defaultValue: "Add", bundle: .module),
                value: "",
                isMultiline: false
            )

            GitInputPanelPresenter.present(dialog: urlDialog, parentWindow: parentWindow) { urlValue in
                let url = urlValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !url.isEmpty else { return }
                self.gitStore.addRemote(name: name, url: url, project: project) { self.statusMessage = $0 }
            }
        }
    }

    func removeGitRemote(_ remote: GitRemoteEntry) {
        guard let project = selectedProject else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "git.remote.remove", defaultValue: "Remove Remote", bundle: .module),
            message: String(format: String(localized: "git.remote.remove.confirm_format", defaultValue: "Are you sure you want to remove remote %@?", bundle: .module), remote.name),
            icon: "trash",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.remove", defaultValue: "Remove", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            if project.gitDefaultPushRemoteName == remote.name,
               let index = self.projects.firstIndex(where: { $0.id == project.id }) {
                self.projects[index].gitDefaultPushRemoteName = nil
                self.persist()
            }
            self.gitStore.removeRemote(remote, project: project) { self.statusMessage = $0 }
        }
    }

    func setDefaultPushRemote(_ remote: GitRemoteEntry) {
        guard let project = selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].gitDefaultPushRemoteName = remote.name
        persist()
        statusMessage = String(format: String(localized: "git.remote.default_push.set_format", defaultValue: "Set %@ as the default push remote.", bundle: .module), remote.name)
    }

    func clearDefaultPushRemote() {
        guard let project = selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].gitDefaultPushRemoteName = nil
        persist()
        statusMessage = String(localized: "git.remote.default_push.cleared", defaultValue: "Restored the Git default push target.", bundle: .module)
    }

    func pushGitBranch() {
        guard let project = selectedProject else { return }

        if let defaultRemote = defaultPushRemote(for: project) {
            pushGitBranch(to: defaultRemote)
            return
        }

        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.push, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func pushGitBranch(_ branch: String? = nil, to remote: GitRemoteEntry) {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForRemote(remote)
        let branchName = branch ?? gitState?.branch ?? "HEAD"
        gitStore.pushBranch(branchName, to: remote, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
            self.promptForGitCredential(completion: completion)
        }, onAuthSucceeded: { credential in
            self.gitCredentialStore.save(credential, for: remote.url)
        })
    }

    func pushCurrentLocalBranch(to remoteBranch: String) {
        guard let project = selectedProject,
              let localBranch = gitState?.branch else { return }

        let parts = remoteBranch.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2,
              let remote = gitRemotes.first(where: { $0.name == parts[0] }) else {
            statusMessage = String(localized: "git.remote.matching_not_found", defaultValue: "Matching remote was not found.", bundle: .module)
            return
        }

        let savedCredential = credentialForRemote(remote)
        gitStore.pushLocalBranch(localBranch, to: remote, remoteBranch: parts[1], project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
            self.promptForGitCredential(completion: completion)
        }, onAuthSucceeded: { credential in
            self.gitCredentialStore.save(credential, for: remote.url)
        })
    }

    func forcePushGitBranch() {
        guard let project = selectedProject else { return }
        let dialog = ConfirmDialogState(
            title: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module),
            message: String(localized: "git.remote.force_push.message", defaultValue: "Overwrite the current remote branch. Only use this when you intentionally want to rewrite remote history.", bundle: .module),
            icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            let savedCredential = self.credentialForSelectedProjectRemote()
            self.gitStore.performRemoteAction(GitRemoteAction.forcePush, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
                if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                    self.gitCredentialStore.save(credential, for: remoteURL)
                }
            }, onConflict: {
                self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
            })
        }
    }

    func revealRepositoryInFinder() {
        guard let project = selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func undoLastGitCommit() {
        guard let project = selectedProject else { return }
        let path = project.path
        let headCommitPushed = (try? gitService.isHeadCommitPushed(at: path)) ?? false

        let dialog = ConfirmDialogState(
            title: String(localized: "git.history.undo_last_commit", defaultValue: "Undo Last Commit", bundle: .module),
            message: headCommitPushed
                ? String(localized: "git.history.undo_last_commit.remote_notice", defaultValue: "Undo the last commit but keep the file changes and staging state. This commit may already be on the remote, so you might need to force push later.", bundle: .module)
                : String(localized: "git.history.undo_last_commit.local_notice", defaultValue: "Undo the last commit but keep the file changes and staging state.", bundle: .module),
            icon: "arrow.uturn.backward",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.undo", defaultValue: "Undo", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            self.gitStore.undoLastCommit(headCommitPushed: headCommitPushed, project: project, onStatus: { self.statusMessage = $0 }, onRewriteWarning: {
                self.presentPostCommitRewriteAlert(actionTitle: String(localized: "git.history.undo_last_commit", defaultValue: "Undo Last Commit", bundle: .module), repositoryPath: path)
            })
        }
    }

    func editLastGitCommitMessage() {
        guard let project = selectedProject else { return }
        let path = project.path
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let currentMessage = (try? gitService.lastCommitMessage(at: path)) ?? ""
        let headCommitPushed = (try? gitService.isHeadCommitPushed(at: path)) ?? false

        let dialog = GitInputDialogState(
            kind: .editLastCommitMessage(headCommitPushed: headCommitPushed),
            title: String(localized: "git.history.edit_last_commit_message", defaultValue: "Edit Last Commit Message", bundle: .module),
            message: headCommitPushed
                ? String(localized: "git.commit.edit_last_message.remote_notice", defaultValue: "Only change the latest commit message. This commit may already be on the remote, so you might need to force push after editing it.", bundle: .module)
                : String(localized: "git.commit.edit_last_message.notice", defaultValue: "Only change the latest commit message.", bundle: .module),
            placeholder: String(localized: "git.commit.edit_last_message.placeholder", defaultValue: "Enter a new commit message", bundle: .module),
            confirmTitle: String(localized: "common.save", defaultValue: "Save", bundle: .module),
            value: currentMessage,
            isMultiline: true
        )

        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] message in
            guard let self, let message else { return }
            self.amendLastGitCommitMessage(message, headCommitPushed: headCommitPushed)
        }
    }

    func syncGitRemote() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.sync, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func createGitBranch() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = GitInputDialogState(
            kind: .createBranch,
            title: String(localized: "git.branch.new", defaultValue: "New Branch", bundle: .module),
            message: String(localized: "git.branch.new.message", defaultValue: "Enter a new branch name.", bundle: .module),
            placeholder: "feature/xxx",
            confirmTitle: String(localized: "common.create", defaultValue: "Create", bundle: .module),
            value: "",
            isMultiline: false
        )

        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] branchName in
            guard let self, let branchName else { return }
            self.createGitBranch(named: branchName)
        }
    }

    private func createGitBranch(named branchName: String, from commitHash: String? = nil) {
        guard let project = selectedProject else { return }
        gitStore.createBranch(branchName, from: commitHash, project: project) { self.statusMessage = $0 }
    }

    private func amendLastGitCommitMessage(_ message: String, headCommitPushed: Bool) {
        guard let project = selectedProject else { return }
        let path = project.path
        gitStore.amendLastCommitMessage(message, headCommitPushed: headCommitPushed, project: project, onStatus: { self.statusMessage = $0 }, onRewriteWarning: {
            self.presentPostCommitRewriteAlert(actionTitle: String(localized: "git.history.edit_last_commit_message", defaultValue: "Edit Last Commit Message", bundle: .module), repositoryPath: path)
        })
    }

    func discard(_ entry: GitFileEntry) {
        guard let project = selectedProject else { return }
        gitStore.discardEntry(entry, project: project) { self.statusMessage = $0 }
    }

    func discardSelectedChanges() {
        guard let project = selectedProject, let gitState else { return }
        let entries = selectedEntries(in: gitState).filter { $0.kind != .staged }
        guard !entries.isEmpty else { return }
        gitStore.discardEntries(entries, project: project, successMessage: String(localized: "git.discard.selected.success", defaultValue: "Discarded selected changes.", bundle: .module)) { self.statusMessage = $0 }
    }

    func stageEntries(_ entries: [GitFileEntry]) {
        guard let project = selectedProject else { return }
        let paths = Array(Set(entries.filter { $0.kind != .staged }.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        gitStore.stagePaths(paths, project: project, successMessage: String(localized: "git.stage.section.success", defaultValue: "Staged files in this section.", bundle: .module)) { self.statusMessage = $0 }
    }

    func unstageEntries(_ entries: [GitFileEntry]) {
        guard let project = selectedProject else { return }
        let paths = Array(Set(entries.filter { $0.kind == .staged }.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        gitStore.unstagePaths(paths, project: project, successMessage: String(localized: "git.unstage.section.success", defaultValue: "Unstaged files in this section.", bundle: .module)) { self.statusMessage = $0 }
    }

    func discardEntries(_ entries: [GitFileEntry]) {
        guard let project = selectedProject else { return }
        guard !entries.isEmpty else { return }
        gitStore.discardEntries(entries, project: project, successMessage: String(localized: "git.discard.section.success", defaultValue: "Discarded changes in this section.", bundle: .module)) { self.statusMessage = $0 }
    }

    func loadDiff(for entry: GitFileEntry) {
        gitStore.loadDiff(for: entry, project: selectedProject)
    }

    func stageAllChanges() {
        guard let project = selectedProject else {
            return
        }
        gitStore.stageAll(project: project) { self.statusMessage = $0 }
    }

    func unstageAllChanges() {
        guard let project = selectedProject else {
            return
        }
        gitStore.unstageAll(project: project) { self.statusMessage = $0 }
    }

    func stageSelectedChanges() {
        guard let project = selectedProject, let gitState else { return }
        let entries = selectedEntries(in: gitState).filter { $0.kind == .changed || $0.kind == .untracked }
        let paths = Array(Set(entries.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        gitStore.stagePaths(paths, project: project, successMessage: String(localized: "git.stage.selected.success", defaultValue: "Staged selected files.", bundle: .module)) { self.statusMessage = $0 }
    }

    func unstageSelectedChanges() {
        guard let project = selectedProject, let gitState else { return }
        let entries = selectedEntries(in: gitState).filter { $0.kind == .staged }
        let paths = Array(Set(entries.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        gitStore.unstagePaths(paths, project: project, successMessage: String(localized: "git.unstage.selected.success", defaultValue: "Unstaged selected files.", bundle: .module)) { self.statusMessage = $0 }
    }

    func stage(_ entry: GitFileEntry) {
        guard let project = selectedProject else {
            return
        }
        gitStore.stagePaths([entry.path], project: project, successMessage: String(format: String(localized: "git.stage.file.success_format", defaultValue: "Staged %@.", bundle: .module), entry.path)) { self.statusMessage = $0 }
    }

    func unstage(_ entry: GitFileEntry) {
        guard let project = selectedProject else {
            return
        }
        gitStore.unstagePaths([entry.path], project: project, successMessage: String(format: String(localized: "git.unstage.file.success_format", defaultValue: "Unstaged %@.", bundle: .module), entry.path)) { self.statusMessage = $0 }
    }

    func commitChanges() {
        performCommitAction(.commit)
    }

    func performCommitAction(_ action: GitCommitAction) {
        guard let project = selectedProject else {
            return
        }

        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = String(localized: "git.commit.message.empty", defaultValue: "Commit message cannot be empty.", bundle: .module)
            return
        }

        gitStore.commit(message: trimmed, action: action, project: project, onStatus: { self.statusMessage = $0 }, onSuccess: {
            self.commitMessage = ""
            self.selectedGitEntry = nil
            self.selectedGitEntryIDs.removeAll()
            self.gitDiffText = String(localized: "git.commit.completed", defaultValue: "Commit completed.", bundle: .module)
        })
    }

    func generateCommitMessage() {
        guard let gitState else {
            statusMessage = String(localized: "git.commit.generate.unavailable", defaultValue: "There are no changes available to generate a commit message.", bundle: .module)
            return
        }

        let fileNames = Array(Set((gitState.staged + gitState.changes + gitState.untracked).map(\.path))).sorted()
        guard !fileNames.isEmpty else {
            statusMessage = String(localized: "git.commit.generate.unavailable", defaultValue: "There are no changes available to generate a commit message.", bundle: .module)
            return
        }

        isGeneratingCommitMessage = true
        let summary = fileNames.prefix(3).joined(separator: ", ")
        let suffix = fileNames.count > 3
            ? String(format: String(localized: "git.commit.generate.more_files_format", defaultValue: " and %@ more files", bundle: .module), "\(fileNames.count)")
            : ""
        commitMessage = String(format: String(localized: "git.commit.generate.summary_format", defaultValue: "Update %@%@ Git workspace interaction", bundle: .module), summary, suffix)
        isGeneratingCommitMessage = false
        statusMessage = String(localized: "git.commit.generate.success", defaultValue: "Generated commit message.", bundle: .module)
    }

    private func entries(for kind: GitFileKind, in state: GitRepositoryState) -> [GitFileEntry] {
        switch kind {
        case .staged:
            return state.staged
        case .changed:
            return state.changes
        case .untracked:
            return state.untracked
        }
    }

    private func selectedEntries(in state: GitRepositoryState) -> [GitFileEntry] {
        let all = state.staged + state.changes + state.untracked
        return all.filter { selectedGitEntryIDs.contains($0.id) }
    }

    private func flatGitEntries(from state: GitRepositoryState) -> [GitFileEntry] {
        state.staged + state.changes + state.untracked
    }

    private func promptForGitCredential(completion: @escaping (GitCredential?) -> Void) {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            completion(nil)
            return
        }

        let dialog = GitCredentialDialogState(
            title: String(localized: "git.credentials.title", defaultValue: "Git Credentials Required", bundle: .module),
            message: String(localized: "git.credentials.message", defaultValue: "Remote access requires authentication. Enter your username and password or token to retry.", bundle: .module),
            confirmTitle: String(localized: "common.continue", defaultValue: "Continue", bundle: .module),
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        GitCredentialDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] credential in
            guard let self else {
                completion(nil)
                return
            }
            guard let credential else {
                self.statusMessage = String(localized: "git.auth.cancelled", defaultValue: "Git authentication was cancelled.", bundle: .module)
                completion(nil)
                return
            }

            guard !credential.username.isEmpty, !credential.password.isEmpty else {
                self.statusMessage = String(localized: "git.auth.credentials_required", defaultValue: "Username and password or token cannot be empty.", bundle: .module)
                completion(nil)
                return
            }

            completion(credential)
        }
    }

    private func credentialForSelectedProjectRemote() -> GitCredential? {
        guard let project = selectedProject,
              let remoteURL = try? gitService.originURL(at: project.path),
              !remoteURL.isEmpty else {
            return nil
        }
        return gitCredentialStore.credential(for: remoteURL)
    }

    private func defaultPushRemote(for project: Project) -> GitRemoteEntry? {
        guard let name = project.gitDefaultPushRemoteName else { return nil }
        return gitRemotes.first(where: { $0.name == name })
    }

    private func credentialForRemote(_ remote: GitRemoteEntry) -> GitCredential? {
        gitCredentialStore.credential(for: remote.url)
    }

    private func presentPostCommitRewriteAlert(actionTitle: String, repositoryPath: String) {
        let dialog = ConfirmDialogState(
            title: actionTitle,
            message: String(localized: "git.history.rewrite_warning.message", defaultValue: "Local history has changed. If the remote still contains the old commits, you may need to force push to sync it.", bundle: .module),
            icon: "arrow.trianglehead.2.clockwise.rotate.90",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "git.history.rewrite_warning.defer", defaultValue: "Handle Later", bundle: .module),
            secondaryTitle: String(localized: "git.history.rewrite_warning.force_push", defaultValue: "Force Push Now", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else { return }
            if result == .secondary {
                guard let project = self.selectedProject else { return }
                let savedCredential = self.credentialForSelectedProjectRemote()
                self.gitStore.performRemoteAction(GitRemoteAction.forcePush, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
                    if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                        self.gitCredentialStore.save(credential, for: remoteURL)
                    }
                }, onConflict: {
                    self.presentRemoteSyncConflictAlert(repositoryPath: repositoryPath)
                })
            } else {
                self.refreshGitState()
            }
        }
    }

    private func refreshGitRemoteSyncState(projectPath: String, projectID: UUID) {
        gitStore.refreshRemoteSyncState(projectPath: projectPath, projectID: projectID)
    }

    private func startGitRemoteSyncPolling() {
        gitStore.startRemoteSyncPolling(
            selectedProject: { self.selectedProject },
            isEnabled: { NSApp.isActive && self.rightPanel == .git }
        )
    }

    private func startGitStatusAutoRefresh() {
        gitStore.startStatusAutoRefresh(
            selectedProject: { self.selectedProject },
            isEnabled: { self.rightPanel == .git }
        )
    }

    private func stopGitRemoteSyncPolling() {
        gitStore.stopRemoteSyncPolling()
    }

    private func stopGitStatusAutoRefresh() {
        gitStore.stopStatusAutoRefresh()
    }

    private func updateGitStatusAutoRefresh() {
        guard rightPanel == .git, selectedProject != nil else {
            stopGitStatusAutoRefresh()
            return
        }
        startGitStatusAutoRefresh()
    }

    func updateGitRemoteSyncPolling() {
        updateGitStatusAutoRefresh()
        guard NSApplication.shared.isActive, rightPanel == .git, selectedProject != nil else {
            stopGitRemoteSyncPolling()
            return
        }
        startGitRemoteSyncPolling()
    }

    private func observeApplicationActivation() {
        let center = NotificationCenter.default

        let becameActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.logApplicationActivationActivity()
                self?.runtimeIngressService.ensureSocketListening()
                self?.performanceMonitor.setApplicationActive(true)
                self?.updateGitRemoteSyncPolling()
                self?.refreshAIStatsIfNeeded()
            }
        }

        let resignedActive = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.performanceMonitor.setApplicationActive(false)
                self?.updateGitRemoteSyncPolling()
            }
        }

        appActivationObservers = [becameActive, resignedActive]
    }

    private func observeTerminalFocusChanges() {
        if let terminalFocusObserver {
            NotificationCenter.default.removeObserver(terminalFocusObserver)
        }
        if let terminalInterruptObserver {
            NotificationCenter.default.removeObserver(terminalInterruptObserver)
        }

        terminalFocusObserver = NotificationCenter.default.addObserver(
            forName: .dmuxTerminalFocusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminalFocusRenderVersion &+= 1
            }
        }

        terminalInterruptObserver = NotificationCenter.default.addObserver(
            forName: .dmuxTerminalInterruptDidSend,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let sessionID = notification.object as? UUID else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                _ = Self.handleManagedTerminalInterrupt(sessionID: sessionID, sessionStore: self.aiSessionStore)
            }
        }
    }

    private func performanceMonitorContextSnapshot() -> AppPerformanceMonitorStore.ContextSnapshot {
        let activityLabel: String
        if let project = selectedProject,
           let phase = activityByProjectID[project.id] {
            switch phase {
            case .idle:
                activityLabel = "idle"
            case .running(let tool):
                activityLabel = "running:\(tool)"
            case .waitingInput(let tool):
                activityLabel = "waiting-input:\(tool)"
            case .completed(let tool, _, let exitCode):
                activityLabel = "completed:\(tool):\(exitCode.map(String.init) ?? "nil")"
            }
        } else {
            activityLabel = "idle"
        }

        return AppPerformanceMonitorStore.ContextSnapshot(
            projectName: selectedProject?.name,
            panelName: rightPanel?.rawValue ?? "none",
            selectedSessionID: selectedSessionID?.uuidString,
            activity: activityLabel
        )
    }

    private func presentRemoteSyncConflictAlert(repositoryPath: String) {
        let dialog = ConfirmDialogState(
            title: String(localized: "git.sync.conflict.title", defaultValue: "Sync Conflict", bundle: .module),
            message: String(localized: "git.sync.conflict.message", defaultValue: "A conflict occurred while pulling. You can resolve it manually first, or force push the current branch directly.", bundle: .module),
            icon: "exclamationmark.triangle.fill",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "git.sync.conflict.resolve_manually", defaultValue: "Resolve Manually", bundle: .module),
            secondaryTitle: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else { return }
            if result == .secondary {
                self.forcePushAfterConflict(at: repositoryPath)
            } else {
                self.statusMessage = String(localized: "git.remote.pull_conflicts", defaultValue: "Pull resulted in conflicts. Resolve them manually first.", bundle: .module)
                self.refreshGitState()
            }
        }
    }

    private func forcePushAfterConflict(at path: String) {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.forcePush, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: path)
        })
    }

    func persist() {
        let snapshot = AppSnapshot(
            projects: projects,
            workspaces: workspaces,
            selectedProjectID: selectedProjectID,
            appSettings: appSettings
        )
        persistenceService.save(snapshot)
    }

    func presentationWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, !(keyWindow is NSPanel) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, !(mainWindow is NSPanel) {
            return mainWindow
        }
        return NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
    }

    func presentDiagnosticsExportError(_ error: Error) {
        guard let parentWindow = presentationWindow() else {
            statusMessage = error.localizedDescription
            return
        }

        statusMessage = error.localizedDescription
        let dialog = ConfirmDialogState(
            title: String(localized: "diagnostics.export.error.title", defaultValue: "Unable to Export Diagnostics", bundle: .module),
            message: error.localizedDescription,
            icon: "tray.and.arrow.down.fill",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module)
        )
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { _ in }
    }

    private func startupRecoveryDialog(for issues: [PersistenceLoadIssue]) -> ConfirmDialogState? {
        guard !issues.isEmpty else {
            return nil
        }

        var lines: [String] = []
        for issue in issues {
            switch issue {
            case let .invalidStateFile(backupFileName):
                if let backupFileName, !backupFileName.isEmpty {
                    lines.append(
                        String(
                            format: String(
                                localized: "startup.recovery.invalid_state.backup_format",
                                defaultValue: "The saved app configuration was invalid and has been reset to defaults. A backup was saved as %@.",
                                bundle: .module
                            ),
                            backupFileName
                        )
                    )
                } else {
                    lines.append(
                        String(
                            localized: "startup.recovery.invalid_state",
                            defaultValue: "The saved app configuration was invalid and has been reset to defaults.",
                            bundle: .module
                        )
                    )
                }
            case .sanitizedState:
                lines.append(
                    String(
                        localized: "startup.recovery.sanitized",
                        defaultValue: "Some saved projects or terminal layout data were invalid and were repaired automatically.",
                        bundle: .module
                    )
                )
            }
        }

        return ConfirmDialogState(
            title: String(localized: "startup.recovery.title", defaultValue: "Recovered App Data", bundle: .module),
            message: lines.joined(separator: "\n\n"),
            icon: "exclamationmark.triangle.fill",
            iconColor: .orange,
            primaryTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module)
        )
    }

    private func startActivityWatchers() {
        activityStatusWatcher?.cancel()

        activityStatusWatcher = makeDirectoryWatcher(for: activityService.statusDirectoryURL())
        runtimeIngressService.startWatching()
        runtimeBridgeObserver = replaceActivityObserver(
            runtimeBridgeObserver,
            name: .dmuxAIRuntimeBridgeDidChange,
            sendNotifications: true,
            refreshAIStats: false,
            requiresStatusReload: false,
            refreshImmediatelyFromRuntime: true
        )
        runtimeActivityObserver = replaceActivityObserver(
            runtimeActivityObserver,
            name: .dmuxAIRuntimeActivityPulse,
            sendNotifications: false,
            refreshAIStats: false,
            requiresStatusReload: false,
            refreshImmediatelyFromRuntime: true
        )
    }

    private func makeDirectoryWatcher(for directoryURL: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            return nil
        }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .link, .extend],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            self?.queueProjectActivityRefresh(
                sendNotifications: true,
                refreshAIStats: true,
                requiresStatusReload: true
            )
        }
        watcher.setCancelHandler {
            close(fd)
        }
        watcher.resume()
        return watcher
    }

    private func replaceActivityObserver(
        _ existingObserver: NSObjectProtocol?,
        name: Notification.Name,
        sendNotifications: Bool,
        refreshAIStats: Bool,
        requiresStatusReload: Bool,
        refreshImmediatelyFromRuntime: Bool
    ) -> NSObjectProtocol {
        if let existingObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }

        return NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if refreshImmediatelyFromRuntime {
                Task { @MainActor [weak self] in
                    self?.refreshProjectActivityImmediatelyFromRuntime(
                        sendNotifications: sendNotifications
                    )
                }
            }
            self?.queueProjectActivityRefresh(
                sendNotifications: sendNotifications,
                refreshAIStats: refreshAIStats,
                requiresStatusReload: requiresStatusReload
            )
        }
    }

    nonisolated private func queueProjectActivityRefresh(
        sendNotifications: Bool,
        refreshAIStats: Bool,
        requiresStatusReload: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.scheduleProjectActivityRefresh(
                sendNotifications: sendNotifications,
                refreshAIStats: refreshAIStats,
                requiresStatusReload: requiresStatusReload
            )
        }
    }

    private func refreshProjectActivityImmediatelyFromRuntime(sendNotifications: Bool) {
        refreshProjectActivity(
            sendNotifications: sendNotifications,
            useCachedStatusesOnly: true
        )
    }

    private func scheduleProjectActivityRefresh(
        sendNotifications: Bool,
        refreshAIStats: Bool,
        requiresStatusReload: Bool
    ) {
        pendingActivityRefreshShouldNotify = pendingActivityRefreshShouldNotify || sendNotifications
        pendingActivityRefreshShouldRefreshAIStats = pendingActivityRefreshShouldRefreshAIStats || refreshAIStats
        pendingActivityRefreshRequiresStatusReload = pendingActivityRefreshRequiresStatusReload || requiresStatusReload

        guard pendingActivityRefreshTask == nil else {
            return
        }

        pendingActivityRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else {
                    return
                }

                let pendingRequest = self.drainPendingActivityRefreshRequest()
                self.pendingActivityRefreshTask = nil

                self.refreshProjectActivity(
                    sendNotifications: pendingRequest.sendNotifications,
                    useCachedStatusesOnly: !pendingRequest.requiresStatusReload
                )
                if pendingRequest.refreshAIStats, self.rightPanel == .aiStats {
                    self.refreshAIStatsIfNeeded()
                }
            }
        }
    }

    func refreshAIStatsIfNeeded() {
        aiStatsStore.refreshIfNeeded(project: selectedProject, projects: projects, selectedSessionID: selectedSessionID)
    }

    private func refreshProjectActivity(
        sendNotifications: Bool,
        useCachedStatusesOnly: Bool = false
    ) {
        let currentProjects = projects
        let payloads = projectActivityPayloads(
            useCachedStatusesOnly: useCachedStatusesOnly,
            projects: currentProjects
        )
        if useCachedStatusesOnly == false {
            runtimeIngressService.importRuntime(projects: currentProjects)
        }

        var phases: [UUID: ProjectActivityPhase] = [:]
        let previousPhases = activityByProjectID

        for project in projects {
            let payload = payloads[project.id]
            let phase = resolvedProjectActivityPhase(projectID: project.id, payload: payload)

            phases[project.id] = phase

            logProjectActivityTransitionIfNeeded(
                projectName: project.name,
                previousPhase: previousPhases[project.id],
                nextPhase: phase
            )

            if sendNotifications {
                handleWaitingInputNotificationIfNeeded(project: project, phase: phase)
                handleCompletionNotificationIfNeeded(project: project, phase: phase, payload: payload)
            }
        }

        if activityByProjectID != phases {
            activityByProjectID = phases
            markActivityStateChanged()
        }
    }

    private func drainPendingActivityRefreshRequest() -> (
        sendNotifications: Bool,
        refreshAIStats: Bool,
        requiresStatusReload: Bool
    ) {
        defer {
            pendingActivityRefreshShouldNotify = false
            pendingActivityRefreshShouldRefreshAIStats = false
            pendingActivityRefreshRequiresStatusReload = false
        }

        return (
            sendNotifications: pendingActivityRefreshShouldNotify,
            refreshAIStats: pendingActivityRefreshShouldRefreshAIStats,
            requiresStatusReload: pendingActivityRefreshRequiresStatusReload
        )
    }

    private func projectActivityPayloads(
        useCachedStatusesOnly: Bool,
        projects: [Project]
    ) -> [UUID: ProjectActivityPayload] {
        if useCachedStatusesOnly {
            return cachedActivityPayloadByProjectID
        }

        let latestPayloads = activityService.loadStatuses(projects: projects)
        cachedActivityPayloadByProjectID = latestPayloads
        return latestPayloads
    }

    private func resolvedCachedProjectActivityPhase(
        payload: ProjectActivityPayload?,
        projectID: UUID
    ) -> ProjectActivityPhase {
        guard let payload else {
            return .idle
        }

        guard isRealtimeAITool(payload.tool) == false else {
            activityService.clearStatus(for: projectID)
            cachedActivityPayloadByProjectID[projectID] = nil
            return .idle
        }

        return sanitizedCachedActivityPhase(activityService.phase(for: payload))
    }

    private func resolvedProjectActivityPhase(
        projectID: UUID,
        payload: ProjectActivityPayload?
    ) -> ProjectActivityPhase {
        var phase = resolvedCachedProjectActivityPhase(payload: payload, projectID: projectID)

        if let payload,
           case .completed = phase,
           clearedCompletionTokenByProjectID[projectID] == activityService.completionToken(for: payload) {
            phase = .idle
        }

        let runtimePhase = aiSessionStore.projectPhase(projectID: projectID)
        if runtimePhase != .idle {
            phase = runtimePhase
        }

        return phase
    }

    private func debugActivityDescription(_ phase: ProjectActivityPhase) -> String {
        switch phase {
        case .idle:
            return "idle"
        case .running(let tool):
            return "running:\(tool)"
        case .waitingInput(let tool):
            return "waiting-input:\(tool)"
        case .completed(let tool, _, let exitCode):
            return "completed:\(tool):\(exitCode.map(String.init) ?? "nil")"
        }
    }

    private func cachedActivityPhase(for projectID: UUID) -> ProjectActivityPhase {
        sanitizedCachedActivityPhase(activityByProjectID[projectID])
    }

    private func cachedActivityDescription(for projectID: UUID) -> String {
        activityByProjectID[projectID].map(debugActivityDescription) ?? "nil"
    }

    private func logProjectActivityTransitionIfNeeded(
        projectName: String,
        previousPhase: ProjectActivityPhase?,
        nextPhase: ProjectActivityPhase
    ) {
        guard previousPhase != nextPhase else {
            return
        }
        debugLog.log(
            "activity",
            "project=\(projectName) phase=\(debugActivityDescription(nextPhase))"
        )
    }

    private func logActivityPhaseResolution(projectID: UUID, source: String, phase: ProjectActivityPhase) {
        let projectName = projects.first(where: { $0.id == projectID })?.name ?? projectID.uuidString
        let runtimeSummary = aiSessionStore.debugSummary(projectID: projectID)
        debugLog.log(
            "activity-phase",
            "project=\(projectName) source=\(source) phase=\(debugActivityDescription(phase)) cached=\(cachedActivityDescription(for: projectID)) runtime=\(runtimeSummary)"
        )
    }

    private func logApplicationActivationActivity() {
        guard let project = selectedProject else {
            debugLog.log("app-activation", "selectedProject=nil")
            return
        }

        let runtimePhase = aiSessionStore.projectPhase(projectID: project.id)
        let runtimeSummary = aiSessionStore.debugSummary(projectID: project.id)
        debugLog.log(
            "app-activation",
            "project=\(project.name) runtimePhase=\(debugActivityDescription(runtimePhase)) cached=\(cachedActivityDescription(for: project.id)) runtime=\(runtimeSummary)"
        )
    }

    private func isRealtimeAITool(_ tool: String) -> Bool {
        runtimeIngressService.isRealtimeTool(tool)
    }

    private func sanitizedCachedActivityPhase(_ phase: ProjectActivityPhase?) -> ProjectActivityPhase {
        guard let phase else {
            return .idle
        }

        switch phase {
        case .running(let tool) where isRealtimeAITool(tool):
            return .idle
        case .waitingInput(let tool) where isRealtimeAITool(tool):
            return .idle
        default:
            return phase
        }
    }

    func clearCompletedActivityIfNeeded(for projectID: UUID) {
        var didClear = false

        lastWaitingInputTokenByProjectID[projectID] = nil

        if case .completed = activityByProjectID[projectID] {
            activityByProjectID[projectID] = .idle
            didClear = true
        }

        if let payload = activityService.loadStatus(projectID: projectID),
           case .completed = activityService.phase(for: payload) {
            let token = activityService.completionToken(for: payload)
            clearedCompletionTokenByProjectID[projectID] = token
            activityByProjectID[projectID] = .idle
            cachedActivityPayloadByProjectID[projectID] = nil
            activityService.clearStatus(for: projectID)
            didClear = true
        }

        if didClear {
            markActivityStateChanged()
        }
    }

    private func markActivityStateChanged() {
        activityRenderVersion &+= 1
        updateDockBadge()
    }

    private func waitingInputNotificationToken(
        tool: String,
        context: AISessionStore.WaitingInputContext
    ) -> String {
        let timestamp = Int(context.updatedAt * 1000)
        return [
            tool,
            String(timestamp),
            context.notificationType ?? "",
            context.targetToolName ?? "",
            context.message ?? ""
        ].joined(separator: "|")
    }

    private func shouldNotifyForWaitingInput(
        _ context: AISessionStore.WaitingInputContext
    ) -> Bool {
        context.notificationType == "permission-request"
    }

    private func handleWaitingInputNotificationIfNeeded(project: Project, phase: ProjectActivityPhase) {
        guard case .waitingInput(let tool) = phase,
              let context = aiSessionStore.waitingInputContext(projectID: project.id),
              shouldNotifyForWaitingInput(context) else {
            lastWaitingInputTokenByProjectID[project.id] = nil
            return
        }

        let token = waitingInputNotificationToken(tool: tool, context: context)
        guard lastWaitingInputTokenByProjectID[project.id] != token else {
            return
        }

        lastWaitingInputTokenByProjectID[project.id] = token
        activityService.notifyNeedsInput(
            projectName: project.name,
            tool: tool,
            notificationType: context.notificationType,
            targetToolName: context.targetToolName,
            message: context.message
        )
    }

    private func handleCompletionNotificationIfNeeded(
        project: Project,
        phase: ProjectActivityPhase,
        payload: ProjectActivityPayload?
    ) {
        guard case .completed(let tool, let finishedAt, let exitCode) = phase else {
            return
        }

        let token = completionActivityToken(payload: payload, tool: tool, finishedAt: finishedAt)

        guard lastCompletionTokenByProjectID[project.id] != token else {
            return
        }

        lastCompletionTokenByProjectID[project.id] = token
        clearedCompletionTokenByProjectID[project.id] = nil
        activityService.notifyCompletion(
            projectName: project.name,
            tool: tool,
            exitCode: exitCode,
            settings: appSettings.notifications
        )
    }

    private func completionActivityToken(
        payload: ProjectActivityPayload?,
        tool: String,
        finishedAt: Date
    ) -> String {
        if let payload {
            return activityService.completionToken(for: payload)
        }

        return "realtime-\(tool)-\(Int(finishedAt.timeIntervalSince1970 * 1000))"
    }

    func updateLanguage(_ language: AppLanguage) {
        var settings = appSettings
        settings.language = language
        appSettings = settings
        persist()
        AppLanguageBootstrap.apply(language: language)
        aiStatsStore.refreshLocalizedStatusTexts()
        presentLanguageRestartPrompt()
    }

    func updateAppIconStyle(_ style: AppIconStyle) {
        var settings = appSettings
        settings.iconStyle = style
        appSettings = settings
        applyAppIcon()
        persist()
    }

    func updateTerminalBackgroundPreset(_ preset: AppTerminalBackgroundPreset) {
        guard appSettings.terminalBackgroundPreset != preset else {
            return
        }
        var settings = appSettings
        settings.terminalBackgroundPreset = preset
        appSettings = settings
        persist()
        presentThemeRestartPrompt()
    }

    func updateBackgroundColorPreset(_ preset: AppBackgroundColorPreset) {
        guard appSettings.backgroundColorPreset != preset else {
            return
        }
        var settings = appSettings
        settings.backgroundColorPreset = preset
        appSettings = settings
        persist()
        presentThemeRestartPrompt()
    }

    func updateTerminalFontSize(_ size: Int) {
        var settings = appSettings
        settings.terminalFontSize = max(10, min(28, size))
        appSettings = settings
        persist()
    }

    func updateDefaultTerminal(_ terminal: AppTerminalProfile) {
        let previousShell = appSettings.defaultTerminal.shellPath
        var settings = appSettings
        settings.defaultTerminal = terminal
        appSettings = settings
        let nextShell = terminal.shellPath
        for index in projects.indices where projects[index].shell == previousShell || AppTerminalProfile.allShellPaths.contains(projects[index].shell) {
            projects[index].shell = nextShell
        }
        for workspaceIndex in workspaces.indices {
            for sessionIndex in workspaces[workspaceIndex].sessions.indices where workspaces[workspaceIndex].sessions[sessionIndex].shell == previousShell || AppTerminalProfile.allShellPaths.contains(workspaces[workspaceIndex].sessions[sessionIndex].shell) {
                workspaces[workspaceIndex].sessions[sessionIndex].shell = nextShell
            }
        }
        persist()
    }

    func updateToolPermissionMode(_ mode: AppAIToolPermissionMode, for tool: AppSupportedAITool) {
        var settings = appSettings
        switch tool {
        case .codex:
            settings.toolPermissions.codex = mode
        case .claudeCode:
            settings.toolPermissions.claudeCode = mode
        case .gemini:
            settings.toolPermissions.gemini = mode
        case .opencode:
            settings.toolPermissions.opencode = mode
        }
        appSettings = settings
        toolPermissionSettingsService.sync(settings.toolPermissions)
        persist()
    }

    func updateNotificationChannelEnabled(_ enabled: Bool, for channel: AppNotificationChannel) {
        updateNotificationChannel(channel) { configuration in
            configuration.isEnabled = enabled
        }
    }

    func updateNotificationChannelEndpoint(_ endpoint: String, for channel: AppNotificationChannel) {
        updateNotificationChannel(channel) { configuration in
            configuration.endpoint = endpoint
        }
    }

    func updateNotificationChannelToken(_ token: String, for channel: AppNotificationChannel) {
        updateNotificationChannel(channel) { configuration in
            configuration.token = token
        }
    }

    func updateDockBadgeEnabled(_ enabled: Bool) {
        var settings = appSettings
        settings.showsDockBadge = enabled
        appSettings = settings
        updateDockBadge()
        persist()
    }

    func updatePetEnabled(_ enabled: Bool) {
        var settings = appSettings
        settings.pet.enabled = enabled
        appSettings = settings
        persist()
    }

    func updatePetStaticMode(_ enabled: Bool) {
        var settings = appSettings
        settings.pet.staticMode = enabled
        appSettings = settings
        persist()
    }

    func updatePetHydrationReminderEnabled(_ enabled: Bool) {
        var settings = appSettings
        settings.pet.hydrationReminderEnabled = enabled
        appSettings = settings
        persist()
    }

    func updatePetHydrationReminderInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.pet.hydrationReminderInterval = interval
        appSettings = settings
        persist()
    }

    func updatePetSedentaryReminderEnabled(_ enabled: Bool) {
        var settings = appSettings
        settings.pet.sedentaryReminderEnabled = enabled
        appSettings = settings
        persist()
    }

    func updatePetSedentaryReminderInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.pet.sedentaryReminderInterval = interval
        appSettings = settings
        persist()
    }

    func updatePetLateNightReminderEnabled(_ enabled: Bool) {
        var settings = appSettings
        settings.pet.lateNightReminderEnabled = enabled
        appSettings = settings
        persist()
    }

    func updatePetLateNightReminderInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.pet.lateNightReminderInterval = interval
        appSettings = settings
        persist()
    }

    func updateShortcut(_ shortcut: AppKeyboardShortcut?, for target: AppShortcutTarget) {
        switch target {
        case .splitPane:
            appSettings.shortcuts.splitPane = shortcut
        case .createTab:
            appSettings.shortcuts.createTab = shortcut
        case .toggleGitPanel:
            appSettings.shortcuts.toggleGitPanel = shortcut
        case .toggleAIPanel:
            appSettings.shortcuts.toggleAIPanel = shortcut
        }
        persist()
    }

    func updateGitAutoRefreshInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.gitAutoRefreshInterval = interval
        appSettings = settings
        gitStore.configureRemoteSyncInterval(interval)
        persist()
    }

    func updateAIAutomaticRefreshInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.aiAutoRefreshInterval = interval
        appSettings = settings
        aiStatsStore.configureIntervals(
            automatic: interval,
            background: appSettings.aiBackgroundRefreshInterval
        )
        persist()
    }

    func updateAIBackgroundRefreshInterval(_ interval: TimeInterval) {
        var settings = appSettings
        settings.aiBackgroundRefreshInterval = interval
        appSettings = settings
        aiStatsStore.configureIntervals(
            automatic: appSettings.aiAutoRefreshInterval,
            background: interval
        )
        persist()
    }

    func updateAIStatisticsDisplayMode(_ mode: AppAIStatisticsDisplayMode) {
        guard appSettings.aiStatisticsDisplayMode != mode else {
            return
        }
        var settings = appSettings
        settings.aiStatisticsDisplayMode = mode
        appSettings = settings
        persist()
    }

    func updateDeveloperPerformanceMonitorEnabled(_ enabled: Bool) {
        applyPerformanceMonitorSettings { developer in
            developer.showsPerformanceMonitor = enabled
        }
    }

    func updateDeveloperPerformanceMonitorSamplingInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(1, interval)
        applyPerformanceMonitorSettings { developer in
            developer.performanceMonitorSamplingInterval = normalizedInterval
        }
    }

    private func applyPerformanceMonitorSettings(_ update: (inout AppDeveloperSettings) -> Void) {
        var settings = appSettings
        update(&settings.developer)
        appSettings = settings
        performanceMonitor.configure(
            isEnabled: settings.developer.showsPerformanceMonitor,
            sampleInterval: settings.developer.performanceMonitorSamplingInterval
        )
        persist()
    }

    private func updateNotificationChannel(
        _ channel: AppNotificationChannel,
        update: (inout AppNotificationChannelConfiguration) -> Void
    ) {
        var settings = appSettings
        switch channel {
        case .bark:
            update(&settings.notifications.bark)
        case .ntfy:
            update(&settings.notifications.ntfy)
        case .wxpusher:
            update(&settings.notifications.wxpusher)
        case .feishu:
            update(&settings.notifications.feishu)
        case .dingTalk:
            update(&settings.notifications.dingTalk)
        case .weCom:
            update(&settings.notifications.weCom)
        case .telegram:
            update(&settings.notifications.telegram)
        case .discord:
            update(&settings.notifications.discord)
        case .slack:
            update(&settings.notifications.slack)
        case .webhook:
            update(&settings.notifications.webhook)
        }
        appSettings = settings
        persist()
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func checkForUpdates() {
        if appUpdaterService.isAvailable {
            do {
                try appUpdaterService.checkForUpdates()
            } catch {
                presentSparkleConfigurationError(error)
            }
            return
        }

        runLegacyUpdateCheck(interactive: true)
    }

    private func scheduleLaunchUpdateCheckIfNeeded() {
        guard hasScheduledLaunchUpdateCheck == false else {
            return
        }
        hasScheduledLaunchUpdateCheck = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else {
                return
            }
            if self.appUpdaterService.isAvailable {
                self.appUpdaterService.performLaunchBackgroundCheckIfNeeded()
            } else {
                self.runLegacyUpdateCheck(interactive: false)
            }
        }
    }

    private func runLegacyUpdateCheck(interactive: Bool) {
        guard !isCheckingForUpdates else {
            return
        }
        isCheckingForUpdates = true
        if interactive {
            statusMessage = String(localized: "update.checking", defaultValue: "Checking for updates...", bundle: .module)
        }

        Task { @MainActor in
            defer { isCheckingForUpdates = false }

            do {
                let result = try await AppReleaseService.checkForUpdates(currentVersion: currentAppVersion)
                presentLegacyUpdateCheckResult(result, interactive: interactive)
            } catch {
                presentLegacyUpdateCheckError(error, interactive: interactive)
            }
        }
    }

    var appDisplayName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
            return name
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !name.isEmpty {
            return name
        }
        return "Codux"
    }

    var appVersionDescription: String {
        let version = currentAppVersion
        let build = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "dev"
        return "v\(version) (\(build))"
    }

    var localizedUserAgreementDocument: String {
        [
            String(localized: "about.user_agreement_body", defaultValue: "This app is currently a development preview. By using it, you understand that terminal, Git, and AI activity features read local project metadata and runtime state, but do not proactively upload your project contents.", bundle: .module),
            String(localized: "about.user_agreement_data", defaultValue: "Codux only reads the local state needed to display terminal sessions, Git repository status, AI tool activity, and local statistics. You are responsible for reviewing any third-party CLI behavior and network activity triggered by those tools.", bundle: .module),
            String(localized: "about.user_agreement_responsibility", defaultValue: "You are responsible for your local environment, file permissions, repository credentials, notification permissions, and any commands executed inside the terminal.", bundle: .module),
            String(localized: "about.user_agreement_license", defaultValue: "Codux is distributed as open-source software under the GPL-3.0 license. Continued use means you accept that this experimental software may change behavior, interface, and compatibility over time.", bundle: .module)
        ].joined(separator: "\n\n")
    }

    var appIconImage: NSImage {
        AppIconRenderer.image(for: appSettings.iconStyle, size: 160)
    }

    private func applyThemeMode() {
        guard isSystemUIReady else {
            return
        }
        let appearance = effectiveThemeMode.appearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            guard !(window is NSPanel) else { continue }
            window.appearance = appearance
        }
    }

    private func applyAppIcon() {
        guard isSystemUIReady else {
            return
        }
        persistApplicationBundleIcon()
        updateDockBadge()
        applyRuntimeDockIcon()
    }

    private func persistApplicationBundleIcon() {
        let bundlePath = Bundle.main.bundleURL.path
        let iconVariant = AppIconRenderer.Variant.current()
        let iconImage: NSImage? = {
            if appSettings.iconStyle == .default {
                return iconVariant == .standard
                    ? nil
                    : AppIconRenderer.image(for: appSettings.iconStyle, size: 1024, variant: iconVariant)
            }
            return AppIconRenderer.image(for: appSettings.iconStyle, size: 1024, variant: iconVariant)
        }()

        let didUpdate = NSWorkspace.shared.setIcon(iconImage, forFile: bundlePath, options: [])
        debugLog.log(
            "app",
            "bundle icon update style=\(appSettings.iconStyle.rawValue) variant=\(String(describing: iconVariant)) success=\(didUpdate) path=\(bundlePath)"
        )

        guard didUpdate else {
            return
        }

        // Nudge Finder and LaunchServices to pick up the custom icon change immediately.
        NSWorkspace.shared.noteFileSystemChanged(bundlePath)
        let parentPath = Bundle.main.bundleURL.deletingLastPathComponent().path
        NSWorkspace.shared.noteFileSystemChanged(parentPath)
    }

    private func updateDockBadge() {
        guard isSystemUIReady else {
            return
        }
        NSApp.dockTile.contentView = nil
        guard appSettings.showsDockBadge else {
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.display()
            return
        }

        let completedCount = activityByProjectID.values.reduce(into: 0) { partial, phase in
            if case .completed = phase {
                partial += 1
            }
        }
        NSApp.dockTile.badgeLabel = completedCount > 0 ? "\(completedCount)" : nil
        NSApp.dockTile.display()
    }

    private func applyRuntimeDockIcon() {
        NSApplication.shared.applicationIconImage = AppIconRenderer.image(
            for: appSettings.iconStyle,
            variant: AppIconRenderer.Variant.current()
        )
    }

    private var currentAppVersion: String {
        ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentLegacyUpdateCheckResult(_ result: AppReleaseCheckResult, interactive: Bool) {
        guard let parentWindow = presentationWindow() else {
            if interactive {
                statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            }
            return
        }

        switch result {
        case .upToDate(let currentVersion, let latestVersion):
            guard interactive else {
                return
            }
            statusMessage = String(localized: "update.latest.title", defaultValue: "You're up to date.", bundle: .module)
            let dialog = ConfirmDialogState(
                title: String(localized: "update.latest.title", defaultValue: "You're up to date.", bundle: .module),
                message: String(
                    format: String(localized: "update.latest.message_format", defaultValue: "Current version: v%@\nLatest release: v%@", bundle: .module),
                    currentVersion,
                    latestVersion
                ),
                icon: "checkmark.circle.fill",
                iconColor: AppTheme.success,
                primaryTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module)
            )
            ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { _ in }

        case .updateAvailable(let currentVersion, let latest):
            statusMessage = String(
                format: String(localized: "update.available.message_format", defaultValue: "A new version v%@ is available. You are currently using v%@.", bundle: .module),
                latest.version,
                currentVersion
            )
            let notes = AppReleaseService.releaseNotesExcerpt(from: latest.body)
            var message = String(
                format: String(localized: "update.available.message_format", defaultValue: "A new version v%@ is available. You are currently using v%@.", bundle: .module),
                latest.version,
                currentVersion
            )
            if let notes, !notes.isEmpty {
                message += "\n\n" + notes
            }

            let dialog = ConfirmDialogState(
                title: String(localized: "update.available.title", defaultValue: "Update Available", bundle: .module),
                message: message,
                icon: "arrow.down.circle.fill",
                iconColor: AppTheme.focus,
                primaryTitle: String(localized: "update.available.open", defaultValue: "Download", bundle: .module),
                secondaryTitle: String(localized: "update.available.later", defaultValue: "Later", bundle: .module)
            )
            ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
                guard let self, result == .primary else {
                    return
                }
                self.openURL(AppReleaseService.preferredDownloadURL(for: latest))
            }
        }
    }

    private func presentLegacyUpdateCheckError(_ error: Error, interactive: Bool) {
        guard interactive else {
            return
        }

        guard let parentWindow = presentationWindow() else {
            statusMessage = error.localizedDescription
            return
        }

        statusMessage = error.localizedDescription
        let dialog = ConfirmDialogState(
            title: String(localized: "update.error.title", defaultValue: "Unable to Check for Updates", bundle: .module),
            message: String(localized: "update.error.message", defaultValue: "Please check your network connection and try again.", bundle: .module),
            icon: "wifi.exclamationmark",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module)
        )
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { _ in }
    }

    private func presentSparkleConfigurationError(_ error: Error) {
        guard let parentWindow = presentationWindow() else {
            statusMessage = error.localizedDescription
            return
        }

        statusMessage = error.localizedDescription
        let dialog = ConfirmDialogState(
            title: String(localized: "update.error.title", defaultValue: "Unable to Check for Updates", bundle: .module),
            message: error.localizedDescription,
            icon: "wifi.exclamationmark",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.ok", defaultValue: "OK", bundle: .module)
        )
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { _ in }
    }

    private func presentLanguageRestartPrompt() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "settings.language.restart_required", defaultValue: "Restart the app to apply the selected language.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "settings.language.restart_title", defaultValue: "Restart Required", bundle: .module),
            message: String(localized: "settings.language.restart_message", defaultValue: "Restart Codux to apply the selected language.", bundle: .module),
            icon: "globe",
            iconColor: AppTheme.focus,
            primaryTitle: String(localized: "common.restart_now", defaultValue: "Restart Now", bundle: .module),
            secondaryTitle: String(localized: "common.later", defaultValue: "Later", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else {
                return
            }
            if result == .primary {
                self.relaunchApplication()
            } else {
                self.statusMessage = String(localized: "settings.language.restart_pending", defaultValue: "Language changes will apply after restart.", bundle: .module)
            }
        }
    }

    private func presentThemeRestartPrompt() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "settings.theme.restart_required", defaultValue: "Restart the app to apply the selected theme.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "settings.theme.restart_title", defaultValue: "Restart Required", bundle: .module),
            message: String(localized: "settings.theme.restart_message", defaultValue: "Restart Codux to apply the selected theme to the app and all terminals.", bundle: .module),
            icon: "paintpalette",
            iconColor: AppTheme.focus,
            primaryTitle: String(localized: "common.restart_now", defaultValue: "Restart Now", bundle: .module),
            secondaryTitle: String(localized: "common.later", defaultValue: "Later", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else {
                return
            }
            if result == .primary {
                self.relaunchApplication()
            } else {
                self.statusMessage = String(localized: "settings.theme.restart_pending", defaultValue: "Theme changes will apply after restart.", bundle: .module)
            }
        }
    }

    private func relaunchApplication() {
        AppDelegate.scheduleRelaunch(at: Bundle.main.bundleURL)
    }

}

enum GitCommitAction: CaseIterable, Hashable {
    case commit
    case commitAndPush
    case commitAndSync

    var title: String {
        switch self {
        case .commit:
            return String(localized: "git.commit.action", defaultValue: "Commit", bundle: .module)
        case .commitAndPush:
            return String(localized: "git.commit.action_push", defaultValue: "Commit and Push", bundle: .module)
        case .commitAndSync:
            return String(localized: "git.commit.action_sync", defaultValue: "Commit and Sync", bundle: .module)
        }
    }

    var successMessage: String {
        switch self {
        case .commit:
            return String(localized: "git.commit.success", defaultValue: "Committed staged changes.", bundle: .module)
        case .commitAndPush:
            return String(localized: "git.commit.push_success", defaultValue: "Committed and pushed changes.", bundle: .module)
        case .commitAndSync:
            return String(localized: "git.commit.sync_success", defaultValue: "Committed and synced changes.", bundle: .module)
        }
    }
}
