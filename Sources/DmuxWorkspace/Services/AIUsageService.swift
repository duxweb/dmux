import Foundation

struct AIUsageService: Sendable {
    private let wrapperStore: AIUsageStore
    private let historyService: AIProjectHistoryService
    private let calendar = Calendar.autoupdatingCurrent

    init(
        wrapperStore: AIUsageStore = AIUsageStore(),
        historyService: AIProjectHistoryService? = nil
    ) {
        self.wrapperStore = wrapperStore
        self.historyService = historyService ?? AIProjectHistoryService(usageStore: wrapperStore)
    }

    func fastPanelState(project: Project, liveSnapshots: [AITerminalSessionSnapshot], currentSnapshot: AITerminalSessionSnapshot?) -> AIStatsPanelState {
        if let indexed = wrapperStore.indexedProjectSnapshot(projectID: project.id) {
            return liveSummaryOnlyState(
                project: project,
                indexed: indexed,
                liveSnapshots: liveSnapshots,
                currentSnapshot: currentSnapshot,
                status: .indexing(progress: 0.0, detail: String(localized: "ai.indexing.starting", defaultValue: "Starting index.", bundle: .module))
            )
        }

        return liveSummaryOnlyState(
            project: project,
            indexed: nil,
            liveSnapshots: liveSnapshots,
            currentSnapshot: currentSnapshot,
            status: .indexing(progress: 0.0, detail: String(localized: "ai.indexing.starting", defaultValue: "Starting index.", bundle: .module))
        )
    }

    func snapshotBackedPanelState(project: Project, liveSnapshots: [AITerminalSessionSnapshot], currentSnapshot: AITerminalSessionSnapshot?, status: AIIndexingStatus) -> AIStatsPanelState {
        if let indexed = wrapperStore.indexedProjectSnapshot(projectID: project.id) {
            return liveSummaryOnlyState(
                project: project,
                indexed: indexed,
                liveSnapshots: liveSnapshots,
                currentSnapshot: currentSnapshot,
                status: status
            )
        }

        return liveSummaryOnlyState(
            project: project,
            indexed: nil,
            liveSnapshots: liveSnapshots,
            currentSnapshot: currentSnapshot,
            status: status
        )
    }

    func lightweightLivePanelState(
        from currentState: AIStatsPanelState,
        project: Project,
        liveSnapshots: [AITerminalSessionSnapshot],
        currentSnapshot: AITerminalSessionSnapshot?,
        status: AIIndexingStatus
    ) -> AIStatsPanelState {
        let liveOverlaySnapshots = overlaySnapshots(from: liveSnapshots)
        let nextLiveOverlayTokens = liveOverlaySnapshots.reduce(0) { $0 + $1.currentTotalTokens }
        let nextLiveOverlayCachedInputTokens = liveOverlaySnapshots.reduce(0) { $0 + $1.currentCachedInputTokens }
        let shouldPreserveCompletedOverlay = liveSnapshots.contains { $0.hasCompletedTurn } &&
            currentState.liveOverlayTokens > nextLiveOverlayTokens
        let preservedCompletedOverlayTokens = preservedOverlayAmount(
            shouldPreserve: shouldPreserveCompletedOverlay,
            current: currentState.liveOverlayTokens,
            next: nextLiveOverlayTokens
        )
        let preservedCompletedOverlayCachedInputTokens = preservedOverlayAmount(
            shouldPreserve: shouldPreserveCompletedOverlay,
            current: currentState.liveOverlayCachedInputTokens,
            next: nextLiveOverlayCachedInputTokens
        )

        var nextState = currentState
        nextState.currentSnapshot = currentSnapshot
        nextState.liveSnapshots = liveSnapshots
        nextState.liveOverlayTokens = nextLiveOverlayTokens
        nextState.liveOverlayCachedInputTokens = nextLiveOverlayCachedInputTokens
        nextState.indexingStatus = status

        if var summary = currentState.projectSummary, summary.projectID == project.id {
            let baseProjectTotal = max(0, summary.projectTotalTokens - currentState.liveOverlayTokens)
            let baseProjectCached = max(0, summary.projectCachedInputTokens - currentState.liveOverlayCachedInputTokens)
            let baseTodayTotal = max(0, summary.todayTotalTokens - currentState.liveOverlayTokens)
            let baseTodayCached = max(0, summary.todayCachedInputTokens - currentState.liveOverlayCachedInputTokens)
            summary.projectTotalTokens = baseProjectTotal + nextLiveOverlayTokens + preservedCompletedOverlayTokens
            summary.projectCachedInputTokens = baseProjectCached + nextLiveOverlayCachedInputTokens + preservedCompletedOverlayCachedInputTokens
            summary.todayTotalTokens = baseTodayTotal + nextLiveOverlayTokens + preservedCompletedOverlayTokens
            summary.todayCachedInputTokens = baseTodayCached + nextLiveOverlayCachedInputTokens + preservedCompletedOverlayCachedInputTokens
            summary.currentSessionTokens = displayedCurrentSessionTokens(from: currentSnapshot)
            summary.currentSessionCachedInputTokens = displayedCurrentSessionCachedInputTokens(from: currentSnapshot)
            summary.currentTool = currentSnapshot?.tool
            summary.currentModel = currentSnapshot?.model
            summary.currentContextUsagePercent = currentSnapshot?.currentContextUsagePercent
            summary.currentContextUsedTokens = currentSnapshot?.currentContextUsedTokens
            summary.currentContextWindow = currentSnapshot?.currentContextWindow
            summary.currentSessionUpdatedAt = currentSnapshot?.updatedAt
            nextState.projectSummary = summary
        } else {
            nextState.projectSummary = baseProjectSummary(
                project: project,
                liveSnapshot: currentSnapshot,
                sessions: currentState.sessions,
                liveOverlayTokens: nextLiveOverlayTokens,
                liveOverlayCachedInputTokens: nextLiveOverlayCachedInputTokens,
                todayTotalTokens: todayTotalTokens(
                    timeBuckets: currentState.todayTimeBuckets,
                    heatmap: currentState.heatmap
                ),
                todayCachedInputTokens: todayCachedInputTokens(
                    timeBuckets: currentState.todayTimeBuckets,
                    heatmap: currentState.heatmap
                )
            )
        }

        return nextState
    }

    func panelState(
        project: Project,
        liveSnapshots: [AITerminalSessionSnapshot],
        currentSnapshot: AITerminalSessionSnapshot?,
        indexingProfile: AIProjectHistoryIndexingProfile = .foreground,
        onProgress: @Sendable @escaping (AIIndexingStatus) async -> Void
    ) async -> AIStatsPanelState {
        do {
            try Task.checkCancellation()
            await onProgress(.indexing(progress: 0.05, detail: String(localized: "ai.indexing.preparing", defaultValue: "Preparing usage data.", bundle: .module)))
            let directorySummary = try await historyService.loadProjectSummary(
                project: project,
                indexingProfile: indexingProfile,
                onProgress: onProgress
            )
            try Task.checkCancellation()
            let todayTotal = todayTotalTokens(
                timeBuckets: directorySummary.todayTimeBuckets,
                heatmap: directorySummary.heatmap
            )
            let indexedSnapshot = AIIndexedProjectSnapshot(
                projectID: project.id,
                projectName: project.name,
                projectSummary: AIProjectUsageSummary(
                    projectID: project.id,
                    projectName: project.name,
                    currentSessionTokens: 0,
                    currentSessionCachedInputTokens: 0,
                    projectTotalTokens: directorySummary.sessions.reduce(0) { $0 + $1.totalTokens },
                    projectCachedInputTokens: directorySummary.sessions.reduce(0) { $0 + $1.cachedInputTokens },
                    todayTotalTokens: todayTotal,
                    todayCachedInputTokens: todayCachedInputTokens(
                        timeBuckets: directorySummary.todayTimeBuckets,
                        heatmap: directorySummary.heatmap
                    ),
                    currentTool: nil,
                    currentModel: nil,
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: directorySummary.sessions.first?.lastSeenAt
                ),
                sessions: directorySummary.sessions,
                heatmap: directorySummary.heatmap,
                todayTimeBuckets: directorySummary.todayTimeBuckets,
                toolBreakdown: directorySummary.toolBreakdown,
                modelBreakdown: directorySummary.modelBreakdown,
                indexedAt: Date()
            )
            wrapperStore.saveProjectIndexState(for: indexedSnapshot, projectPath: project.path)

            return liveSummaryOnlyState(
                project: project,
                indexed: indexedSnapshot,
                liveSnapshots: liveSnapshots,
                currentSnapshot: currentSnapshot,
                status: .completed(detail: String(localized: "ai.indexing.complete", defaultValue: "Index complete.", bundle: .module))
            )
        } catch is CancellationError {
            return snapshotBackedPanelState(
                project: project,
                liveSnapshots: liveSnapshots,
                currentSnapshot: currentSnapshot,
                status: .cancelled(detail: String(localized: "ai.indexing.stopped", defaultValue: "Indexing stopped.", bundle: .module))
            )
        } catch {
            return snapshotBackedPanelState(
                project: project,
                liveSnapshots: liveSnapshots,
                currentSnapshot: currentSnapshot,
                status: .failed(detail: (error as NSError).localizedDescription)
            )
        }
    }

    private func liveSummaryOnlyState(
        project: Project,
        indexed: AIIndexedProjectSnapshot?,
        liveSnapshots: [AITerminalSessionSnapshot],
        currentSnapshot: AITerminalSessionSnapshot?,
        status: AIIndexingStatus
    ) -> AIStatsPanelState {
        let liveOverlaySnapshots = overlaySnapshots(from: liveSnapshots)
        let totalLiveDelta = liveOverlaySnapshots.reduce(0) { $0 + $1.currentTotalTokens }
        let totalLiveCachedDelta = liveOverlaySnapshots.reduce(0) { $0 + $1.currentCachedInputTokens }

        var summary = indexed?.projectSummary ?? AIProjectUsageSummary(
            projectID: project.id,
            projectName: project.name,
            currentSessionTokens: 0,
            currentSessionCachedInputTokens: 0,
            projectTotalTokens: 0,
            projectCachedInputTokens: 0,
            todayTotalTokens: 0,
            todayCachedInputTokens: 0,
            currentTool: nil,
            currentModel: nil,
            currentContextUsagePercent: nil,
            currentContextUsedTokens: nil,
            currentContextWindow: nil,
            currentSessionUpdatedAt: nil
        )

        summary.projectID = project.id
        summary.projectName = project.name
        summary.projectTotalTokens = (indexed?.projectSummary.projectTotalTokens ?? 0) + totalLiveDelta
        summary.projectCachedInputTokens = (indexed?.projectSummary.projectCachedInputTokens ?? 0) + totalLiveCachedDelta
        summary.todayTotalTokens = todayTotalTokens(
            timeBuckets: indexed?.todayTimeBuckets ?? [],
            heatmap: indexed?.heatmap ?? []
        ) + totalLiveDelta
        summary.todayCachedInputTokens = todayCachedInputTokens(
            timeBuckets: indexed?.todayTimeBuckets ?? [],
            heatmap: indexed?.heatmap ?? []
        ) + totalLiveCachedDelta
        summary.currentSessionTokens = displayedCurrentSessionTokens(from: currentSnapshot)
        summary.currentSessionCachedInputTokens = displayedCurrentSessionCachedInputTokens(from: currentSnapshot)
        summary.currentTool = currentSnapshot?.tool
        summary.currentModel = currentSnapshot?.model
        summary.currentContextUsagePercent = currentSnapshot?.currentContextUsagePercent
        summary.currentContextUsedTokens = currentSnapshot?.currentContextUsedTokens
        summary.currentContextWindow = currentSnapshot?.currentContextWindow
        summary.currentSessionUpdatedAt = currentSnapshot?.updatedAt ?? indexed?.projectSummary.currentSessionUpdatedAt

        return AIStatsPanelState(
            projectSummary: summary,
            currentSnapshot: currentSnapshot,
            liveSnapshots: liveSnapshots,
            liveOverlayTokens: totalLiveDelta,
            liveOverlayCachedInputTokens: totalLiveCachedDelta,
            sessions: indexed?.sessions ?? [],
            heatmap: indexed?.heatmap ?? [],
            todayTimeBuckets: indexed?.todayTimeBuckets ?? [],
            toolBreakdown: indexed?.toolBreakdown ?? [],
            modelBreakdown: indexed?.modelBreakdown ?? [],
            indexedAt: indexed?.indexedAt,
            indexingStatus: status
        )
    }

    private func overlaySnapshots(from liveSnapshots: [AITerminalSessionSnapshot]) -> [AITerminalSessionSnapshot] {
        liveSnapshots.map { snapshot in
            var overlaySnapshot = snapshot
            overlaySnapshot.currentInputTokens = max(0, snapshot.currentInputTokens - snapshot.baselineInputTokens)
            overlaySnapshot.currentOutputTokens = max(0, snapshot.currentOutputTokens - snapshot.baselineOutputTokens)
            overlaySnapshot.currentTotalTokens = max(0, snapshot.currentTotalTokens - snapshot.baselineTotalTokens)
            overlaySnapshot.currentCachedInputTokens = max(0, snapshot.currentCachedInputTokens - snapshot.baselineCachedInputTokens)
            return overlaySnapshot
        }
    }

    private func baseProjectSummary(
        project: Project,
        liveSnapshot: AITerminalSessionSnapshot?,
        sessions: [AISessionSummary],
        liveOverlayTokens: Int,
        liveOverlayCachedInputTokens: Int,
        todayTotalTokens: Int,
        todayCachedInputTokens: Int
    ) -> AIProjectUsageSummary {
        AIProjectUsageSummary(
            projectID: project.id,
            projectName: project.name,
            currentSessionTokens: displayedCurrentSessionTokens(from: liveSnapshot),
            currentSessionCachedInputTokens: displayedCurrentSessionCachedInputTokens(from: liveSnapshot),
            projectTotalTokens: sessions.reduce(0) { $0 + $1.totalTokens } + liveOverlayTokens,
            projectCachedInputTokens: sessions.reduce(0) { $0 + $1.cachedInputTokens } + liveOverlayCachedInputTokens,
            todayTotalTokens: todayTotalTokens + liveOverlayTokens,
            todayCachedInputTokens: todayCachedInputTokens + liveOverlayCachedInputTokens,
            currentTool: liveSnapshot?.tool,
            currentModel: liveSnapshot?.model,
            currentContextUsagePercent: liveSnapshot?.currentContextUsagePercent,
            currentContextUsedTokens: liveSnapshot?.currentContextUsedTokens,
            currentContextWindow: liveSnapshot?.currentContextWindow,
            currentSessionUpdatedAt: liveSnapshot?.updatedAt
        )
    }

    private func preservedOverlayAmount(
        shouldPreserve: Bool,
        current: Int,
        next: Int
    ) -> Int {
        guard shouldPreserve, current > next else {
            return 0
        }
        return current - next
    }

    private func displayedCurrentSessionTokens(from snapshot: AITerminalSessionSnapshot?) -> Int {
        guard let snapshot else {
            return 0
        }
        return snapshot.currentTotalTokens
    }

    private func displayedCurrentSessionCachedInputTokens(from snapshot: AITerminalSessionSnapshot?) -> Int {
        guard let snapshot else {
            return 0
        }
        return snapshot.currentCachedInputTokens
    }

    private func todayTotalTokens(timeBuckets: [AITimeBucket], heatmap: [AIHeatmapDay]) -> Int {
        let bucketTotal = timeBuckets.reduce(0) { $0 + $1.totalTokens }
        if bucketTotal > 0 {
            return bucketTotal
        }

        let today = calendar.startOfDay(for: Date())
        return heatmap.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.totalTokens ?? 0
    }

    private func todayCachedInputTokens(timeBuckets: [AITimeBucket], heatmap: [AIHeatmapDay]) -> Int {
        let bucketTotal = timeBuckets.reduce(0) { $0 + $1.cachedInputTokens }
        if bucketTotal > 0 {
            return bucketTotal
        }

        let today = calendar.startOfDay(for: Date())
        return heatmap.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.cachedInputTokens ?? 0
    }
}
