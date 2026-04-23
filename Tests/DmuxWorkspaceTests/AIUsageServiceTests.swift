import XCTest
@testable import DmuxWorkspace

final class AIUsageServiceTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmux-ai-usage-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        databaseURL = temporaryDirectoryURL.appendingPathComponent("ai-usage.sqlite3", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        databaseURL = nil
    }

    func testSnapshotBackedPanelStateRemainsScopedToSelectedProject() {
        let store = AIUsageStore(databaseURL: databaseURL)
        let service = AIUsageService(wrapperStore: store)
        let sharedFilePath = "/tmp/shared-claude-history.jsonl"
        let modifiedAt = 1_713_690_000.0
        let indexedAt = Date(timeIntervalSince1970: 1_713_690_123)

        let projectA = makeProject(name: "Project A", path: "/tmp/project-a")
        let projectB = makeProject(name: "Project B", path: "/tmp/project-b")

        store.deleteExternalSummaries(projectPath: projectA.path)
        store.deleteExternalSummaries(projectPath: projectB.path)
        store.deleteProjectIndexState(projectID: projectA.id)
        store.deleteProjectIndexState(projectID: projectB.id)

        store.saveExternalSummary(
            AIExternalFileSummary(
                source: "claude",
                filePath: sharedFilePath,
                fileModifiedAt: modifiedAt,
                projectPath: projectA.path,
                usageBuckets: [makeUsageBucket(project: projectA, externalSessionID: "a-1", totalTokens: 111)],
                sessions: [makeSessionSummary(project: projectA, externalSessionID: "a-1", totalTokens: 111)],
                dayUsage: [AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: Date()), totalTokens: 111, requestCount: 1)],
                timeBuckets: []
            )
        )
        store.saveExternalSummary(
            AIExternalFileSummary(
                source: "claude",
                filePath: sharedFilePath,
                fileModifiedAt: modifiedAt,
                projectPath: projectB.path,
                usageBuckets: [makeUsageBucket(project: projectB, externalSessionID: "b-1", totalTokens: 222)],
                sessions: [makeSessionSummary(project: projectB, externalSessionID: "b-1", totalTokens: 222)],
                dayUsage: [AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: Date()), totalTokens: 222, requestCount: 1)],
                timeBuckets: []
            )
        )

        store.saveProjectIndexState(for:
            makeIndexedSnapshot(project: projectA, totalTokens: 111, indexedAt: indexedAt),
            projectPath: projectA.path
        )
        store.saveProjectIndexState(for:
            makeIndexedSnapshot(project: projectB, totalTokens: 222, indexedAt: indexedAt),
            projectPath: projectB.path
        )

        let panelA = service.snapshotBackedPanelState(
            project: projectA,
            liveSnapshots: [],
            currentSnapshot: nil,
            status: .completed(detail: "done")
        )
        let panelB = service.snapshotBackedPanelState(
            project: projectB,
            liveSnapshots: [],
            currentSnapshot: nil,
            status: .completed(detail: "done")
        )

        XCTAssertEqual(panelA.projectSummary?.projectID, projectA.id)
        XCTAssertEqual(panelA.projectSummary?.projectTotalTokens, 111)
        XCTAssertEqual(panelA.projectSummary?.projectCachedInputTokens, 0)
        XCTAssertEqual(panelA.projectSummary?.todayTotalTokens, 111)
        XCTAssertEqual(panelA.sessions.map(\.totalTokens), [111])

        XCTAssertEqual(panelB.projectSummary?.projectID, projectB.id)
        XCTAssertEqual(panelB.projectSummary?.projectTotalTokens, 222)
        XCTAssertEqual(panelB.projectSummary?.projectCachedInputTokens, 0)
        XCTAssertEqual(panelB.projectSummary?.todayTotalTokens, 222)
        XCTAssertEqual(panelB.sessions.map(\.totalTokens), [222])
    }

    func testLightweightLivePanelStateCarriesCachedOverlayTokensSeparately() {
        let store = AIUsageStore(databaseURL: databaseURL)
        let service = AIUsageService(wrapperStore: store)
        let project = makeProject(name: "Project A", path: "/tmp/project-a")

        let baselineState = AIStatsPanelState(
            projectSummary: AIProjectUsageSummary(
                projectID: project.id,
                projectName: project.name,
                currentSessionTokens: 0,
                currentSessionCachedInputTokens: 0,
                projectTotalTokens: 500,
                projectCachedInputTokens: 120,
                todayTotalTokens: 300,
                todayCachedInputTokens: 80,
                currentTool: nil,
                currentModel: nil,
                currentContextUsagePercent: nil,
                currentContextUsedTokens: nil,
                currentContextWindow: nil,
                currentSessionUpdatedAt: nil
            ),
            currentSnapshot: nil,
            liveSnapshots: [],
            liveOverlayTokens: 0,
            liveOverlayCachedInputTokens: 0,
            sessions: [],
            heatmap: [],
            todayTimeBuckets: [],
            toolBreakdown: [],
            modelBreakdown: [],
            indexedAt: nil,
            indexingStatus: .completed(detail: "done")
        )

        let liveSnapshot = AITerminalSessionSnapshot(
            sessionID: UUID(),
            externalSessionID: "claude-1",
            projectID: project.id,
            projectName: project.name,
            sessionTitle: "Live",
            tool: "claude",
            model: "claude-sonnet-4-6",
            status: "running",
            isRunning: true,
            startedAt: nil,
            updatedAt: Date(),
            currentInputTokens: 40,
            currentOutputTokens: 15,
            currentTotalTokens: 55,
            currentCachedInputTokens: 20,
            baselineInputTokens: 10,
            baselineOutputTokens: 5,
            baselineTotalTokens: 15,
            baselineCachedInputTokens: 8,
            currentContextWindow: nil,
            currentContextUsedTokens: nil,
            currentContextUsagePercent: nil,
            wasInterrupted: false,
            hasCompletedTurn: false
        )

        let nextState = service.lightweightLivePanelState(
            from: baselineState,
            project: project,
            liveSnapshots: [liveSnapshot],
            currentSnapshot: liveSnapshot,
            status: .completed(detail: "done")
        )

        XCTAssertEqual(nextState.projectSummary?.projectTotalTokens, 540)
        XCTAssertEqual(nextState.projectSummary?.projectCachedInputTokens, 132)
        XCTAssertEqual(nextState.projectSummary?.todayTotalTokens, 340)
        XCTAssertEqual(nextState.projectSummary?.todayCachedInputTokens, 92)
        XCTAssertEqual(nextState.projectSummary?.currentSessionTokens, 55)
        XCTAssertEqual(nextState.projectSummary?.currentSessionCachedInputTokens, 20)
        XCTAssertEqual(nextState.currentSnapshot?.currentTotalTokens, 55)
        XCTAssertEqual(nextState.currentSnapshot?.currentCachedInputTokens, 20)
    }

    func testLightweightLivePanelStateFallbackSummaryIncludesLiveOverlay() {
        let store = AIUsageStore(databaseURL: databaseURL)
        let service = AIUsageService(wrapperStore: store)
        let project = makeProject(name: "Project A", path: "/tmp/project-a")

        let baselineState = AIStatsPanelState(
            projectSummary: nil,
            currentSnapshot: nil,
            liveSnapshots: [],
            liveOverlayTokens: 0,
            liveOverlayCachedInputTokens: 0,
            sessions: [makeSessionSummary(project: project, externalSessionID: "a-1", totalTokens: 500)],
            heatmap: [],
            todayTimeBuckets: [],
            toolBreakdown: [],
            modelBreakdown: [],
            indexedAt: nil,
            indexingStatus: .completed(detail: "done")
        )

        let liveSnapshot = AITerminalSessionSnapshot(
            sessionID: UUID(),
            externalSessionID: "claude-1",
            projectID: project.id,
            projectName: project.name,
            sessionTitle: "Live",
            tool: "claude",
            model: "claude-sonnet-4-6",
            status: "running",
            isRunning: true,
            startedAt: nil,
            updatedAt: Date(),
            currentInputTokens: 40,
            currentOutputTokens: 15,
            currentTotalTokens: 55,
            currentCachedInputTokens: 20,
            baselineInputTokens: 10,
            baselineOutputTokens: 5,
            baselineTotalTokens: 15,
            baselineCachedInputTokens: 8,
            currentContextWindow: nil,
            currentContextUsedTokens: nil,
            currentContextUsagePercent: nil,
            wasInterrupted: false,
            hasCompletedTurn: false
        )

        let nextState = service.lightweightLivePanelState(
            from: baselineState,
            project: project,
            liveSnapshots: [liveSnapshot],
            currentSnapshot: liveSnapshot,
            status: .completed(detail: "done")
        )

        XCTAssertEqual(nextState.projectSummary?.projectTotalTokens, 540)
        XCTAssertEqual(nextState.projectSummary?.projectCachedInputTokens, 12)
        XCTAssertEqual(nextState.projectSummary?.todayTotalTokens, 40)
        XCTAssertEqual(nextState.projectSummary?.todayCachedInputTokens, 12)
        XCTAssertEqual(nextState.projectSummary?.currentSessionTokens, 55)
        XCTAssertEqual(nextState.projectSummary?.currentSessionCachedInputTokens, 20)
        XCTAssertEqual(nextState.currentSnapshot?.currentTotalTokens, 55)
        XCTAssertEqual(nextState.currentSnapshot?.currentCachedInputTokens, 20)
    }

    func testLightweightLivePanelStatePreservesCompletedOverlayUntilIndexedRefresh() {
        let store = AIUsageStore(databaseURL: databaseURL)
        let service = AIUsageService(wrapperStore: store)
        let project = makeProject(name: "Project A", path: "/tmp/project-a")

        let baselineState = AIStatsPanelState(
            projectSummary: AIProjectUsageSummary(
                projectID: project.id,
                projectName: project.name,
                currentSessionTokens: 40,
                currentSessionCachedInputTokens: 12,
                projectTotalTokens: 540,
                projectCachedInputTokens: 132,
                todayTotalTokens: 340,
                todayCachedInputTokens: 92,
                currentTool: "claude",
                currentModel: "claude-sonnet-4-6",
                currentContextUsagePercent: nil,
                currentContextUsedTokens: nil,
                currentContextWindow: nil,
                currentSessionUpdatedAt: nil
            ),
            currentSnapshot: nil,
            liveSnapshots: [],
            liveOverlayTokens: 40,
            liveOverlayCachedInputTokens: 12,
            sessions: [],
            heatmap: [],
            todayTimeBuckets: [],
            toolBreakdown: [],
            modelBreakdown: [],
            indexedAt: nil,
            indexingStatus: .completed(detail: "done")
        )

        let completedSnapshot = AITerminalSessionSnapshot(
            sessionID: UUID(),
            externalSessionID: "claude-1",
            projectID: project.id,
            projectName: project.name,
            sessionTitle: "Live",
            tool: "claude",
            model: "claude-sonnet-4-6",
            status: "completed",
            isRunning: false,
            startedAt: nil,
            updatedAt: Date(),
            currentInputTokens: 40,
            currentOutputTokens: 15,
            currentTotalTokens: 55,
            currentCachedInputTokens: 20,
            baselineInputTokens: 40,
            baselineOutputTokens: 15,
            baselineTotalTokens: 55,
            baselineCachedInputTokens: 20,
            currentContextWindow: nil,
            currentContextUsedTokens: nil,
            currentContextUsagePercent: nil,
            wasInterrupted: false,
            hasCompletedTurn: true
        )

        let nextState = service.lightweightLivePanelState(
            from: baselineState,
            project: project,
            liveSnapshots: [completedSnapshot],
            currentSnapshot: completedSnapshot,
            status: .completed(detail: "done")
        )

        XCTAssertEqual(nextState.projectSummary?.projectTotalTokens, 540)
        XCTAssertEqual(nextState.projectSummary?.projectCachedInputTokens, 132)
        XCTAssertEqual(nextState.projectSummary?.todayTotalTokens, 340)
        XCTAssertEqual(nextState.projectSummary?.todayCachedInputTokens, 92)
        XCTAssertEqual(nextState.projectSummary?.currentSessionTokens, 55)
        XCTAssertEqual(nextState.projectSummary?.currentSessionCachedInputTokens, 20)
        XCTAssertEqual(nextState.currentSnapshot?.currentTotalTokens, 55)
        XCTAssertEqual(nextState.currentSnapshot?.currentCachedInputTokens, 20)
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            id: UUID(),
            name: name,
            path: path,
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
    }

    private func makeSessionSummary(project: Project, externalSessionID: String, totalTokens: Int) -> AISessionSummary {
        AISessionSummary(
            sessionID: UUID(),
            externalSessionID: externalSessionID,
            projectID: project.id,
            projectName: project.name,
            sessionTitle: externalSessionID,
            firstSeenAt: Date(timeIntervalSince1970: 1_713_600_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_713_600_100),
            lastTool: "claude",
            lastModel: "claude-sonnet-4-6",
            requestCount: 1,
            totalInputTokens: totalTokens,
            totalOutputTokens: 0,
            totalTokens: totalTokens,
            maxContextUsagePercent: nil,
            activeDurationSeconds: 60,
            todayTokens: totalTokens
        )
    }

    private func makeUsageBucket(project: Project, externalSessionID: String, totalTokens: Int) -> AIUsageBucket {
        let start = Calendar.autoupdatingCurrent.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        let end = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: start) ?? start
        return AIUsageBucket(
            source: "claude",
            sessionKey: externalSessionID,
            externalSessionID: externalSessionID,
            sessionTitle: externalSessionID,
            model: "claude-sonnet-4-6",
            projectID: project.id,
            projectName: project.name,
            bucketStart: start,
            bucketEnd: end,
            inputTokens: totalTokens,
            outputTokens: 0,
            totalTokens: totalTokens,
            cachedInputTokens: 0,
            requestCount: 1,
            activeDurationSeconds: 60,
            firstSeenAt: start,
            lastSeenAt: start.addingTimeInterval(60)
        )
    }

    private func makeIndexedSnapshot(project: Project, totalTokens: Int, indexedAt: Date) -> AIIndexedProjectSnapshot {
        AIIndexedProjectSnapshot(
            projectID: project.id,
            projectName: project.name,
            projectSummary: AIProjectUsageSummary(
                projectID: project.id,
                projectName: project.name,
                currentSessionTokens: 0,
                projectTotalTokens: totalTokens,
                todayTotalTokens: totalTokens,
                currentTool: nil,
                currentModel: nil,
                currentContextUsagePercent: nil,
                currentContextUsedTokens: nil,
                currentContextWindow: nil,
                currentSessionUpdatedAt: nil
            ),
            sessions: [],
            heatmap: [],
            todayTimeBuckets: [],
            toolBreakdown: [],
            modelBreakdown: [],
            indexedAt: indexedAt
        )
    }
}
