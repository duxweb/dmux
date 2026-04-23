import XCTest
@testable import DmuxWorkspace

@MainActor
final class AIStatsStoreMetricsTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!

    override func setUp() async throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmux-ai-stats-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        databaseURL = temporaryDirectoryURL.appendingPathComponent("ai-usage.sqlite3", isDirectory: false)
        AISessionStore.shared.reset()
    }

    override func tearDown() async throws {
        AISessionStore.shared.reset()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        databaseURL = nil
    }

    func testResolvedTodayTotalTokensPrefersLiveSummaryOverIndexedBuckets() {
        let store = AIStatsStore()
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let bucketStart = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 10, to: today) ?? today
        let bucketEnd = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: bucketStart) ?? bucketStart

        let resolved = store.resolvedTodayTotalTokens(
            summary: 2_920_000,
            timeBuckets: [
                AITimeBucket(
                    start: bucketStart,
                    end: bucketEnd,
                    totalTokens: 1_400_000,
                    cachedInputTokens: 0,
                    requestCount: 1
                )
            ],
            heatmap: [
                AIHeatmapDay(
                    day: today,
                    totalTokens: 1_400_000,
                    cachedInputTokens: 0,
                    requestCount: 1
                )
            ]
        )

        XCTAssertEqual(resolved, 2_920_000)
    }

    func testResolvedDisplayedTodayTotalTokensPrefersLiveSummaryOverIndexedBuckets() {
        let store = AIStatsStore()
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let bucketStart = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 10, to: today) ?? today
        let bucketEnd = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: bucketStart) ?? bucketStart

        let resolved = store.resolvedDisplayedTodayTotalTokens(
            summary: 2_920_000,
            summaryCached: 120_000,
            timeBuckets: [
                AITimeBucket(
                    start: bucketStart,
                    end: bucketEnd,
                    totalTokens: 1_400_000,
                    cachedInputTokens: 60_000,
                    requestCount: 1
                )
            ],
            heatmap: [
                AIHeatmapDay(
                    day: today,
                    totalTokens: 1_400_000,
                    cachedInputTokens: 60_000,
                    requestCount: 1
                )
            ]
        )

        XCTAssertEqual(resolved, 3_040_000)
    }

    func testTitlebarTodayLevelTokensUsesCachedProjectStateIncludingLiveOverlay() {
        let store = makeStore()
        let project = Project(
            id: UUID(),
            name: "Codux",
            path: "/tmp/codux",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )

        store.currentProjects = [project]
        store.cacheState(
            AIStatsPanelState(
                projectSummary: AIProjectUsageSummary(
                    projectID: project.id,
                    projectName: project.name,
                    currentSessionTokens: 1_390,
                    currentSessionCachedInputTokens: 190,
                    projectTotalTokens: 10_100_000,
                    projectCachedInputTokens: 1_200_000,
                    todayTotalTokens: 2_920_000,
                    todayCachedInputTokens: 120_000,
                    currentTool: "codex",
                    currentModel: "gpt-5.4",
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: nil
                ),
                currentSnapshot: nil,
                liveSnapshots: [],
                liveOverlayTokens: 100,
                liveOverlayCachedInputTokens: 20,
                sessions: [],
                heatmap: [
                    AIHeatmapDay(
                        day: Calendar.autoupdatingCurrent.startOfDay(for: Date()),
                        totalTokens: 2_820_000,
                        cachedInputTokens: 0,
                        requestCount: 1
                    )
                ],
                todayTimeBuckets: [
                    AITimeBucket(
                        start: Date(),
                        end: Date().addingTimeInterval(3600),
                        totalTokens: 2_820_000,
                        cachedInputTokens: 0,
                        requestCount: 1
                    )
                ],
                toolBreakdown: [],
                modelBreakdown: [],
                indexedAt: nil,
                indexingStatus: .completed(detail: "done")
            ),
            for: project.id
        )

        seedLiveSession(
            terminalID: UUID(),
            project: project,
            externalSessionID: "cached-overlay-live",
            totalTokens: 100,
            baselineTotalTokens: 0
        )

        XCTAssertEqual(store.titlebarTodayLevelTokens(), 2_920_000)
    }

    func testTitlebarTodayLevelTokensUsesFreshLiveOverlayAcrossAllCurrentProjects() {
        let store = makeStore()
        let projectA = makeProject(name: "Project A", path: "/tmp/project-a")
        let projectB = makeProject(name: "Project B", path: "/tmp/project-b")
        store.currentProjects = [projectA, projectB]

        store.cacheState(
            AIStatsPanelState(
                projectSummary: AIProjectUsageSummary(
                    projectID: projectA.id,
                    projectName: projectA.name,
                    currentSessionTokens: 0,
                    currentSessionCachedInputTokens: 0,
                    projectTotalTokens: 1_200,
                    projectCachedInputTokens: 0,
                    todayTotalTokens: 500,
                    todayCachedInputTokens: 0,
                    currentTool: nil,
                    currentModel: nil,
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: nil
                ),
                currentSnapshot: nil,
                liveSnapshots: [],
                liveOverlayTokens: 100,
                liveOverlayCachedInputTokens: 0,
                sessions: [],
                heatmap: [],
                todayTimeBuckets: [],
                toolBreakdown: [],
                modelBreakdown: [],
                indexedAt: nil,
                indexingStatus: .completed(detail: "done")
            ),
            for: projectA.id
        )
        store.cacheState(
            AIStatsPanelState(
                projectSummary: AIProjectUsageSummary(
                    projectID: projectB.id,
                    projectName: projectB.name,
                    currentSessionTokens: 0,
                    currentSessionCachedInputTokens: 0,
                    projectTotalTokens: 2_400,
                    projectCachedInputTokens: 0,
                    todayTotalTokens: 800,
                    todayCachedInputTokens: 0,
                    currentTool: nil,
                    currentModel: nil,
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: nil
                ),
                currentSnapshot: nil,
                liveSnapshots: [],
                liveOverlayTokens: 20,
                liveOverlayCachedInputTokens: 0,
                sessions: [],
                heatmap: [],
                todayTimeBuckets: [],
                toolBreakdown: [],
                modelBreakdown: [],
                indexedAt: nil,
                indexingStatus: .completed(detail: "done")
            ),
            for: projectB.id
        )

        seedLiveSession(
            terminalID: UUID(),
            project: projectA,
            externalSessionID: "a-live",
            totalTokens: 160,
            baselineTotalTokens: 100
        )
        seedLiveSession(
            terminalID: UUID(),
            project: projectB,
            externalSessionID: "b-live",
            totalTokens: 90,
            baselineTotalTokens: 20
        )

        XCTAssertEqual(store.titlebarTodayLevelTokens(), 1_310)
        XCTAssertEqual(store.totalAllTimeNormalizedTokensAcrossProjects([projectA, projectB]), 3_610)
    }

    func testPetTotalsIgnorePreClaimHistoryFromNewlyAddedProjectButCountPostClaimGrowth() {
        let aiUsageStore = AIUsageStore(databaseURL: databaseURL)
        let store = makeStore(aiUsageStore: aiUsageStore)
        let claimDate = Date(timeIntervalSince1970: 1_700_000_000)
        let projectA = makeProject(name: "Project A", path: "/tmp/project-a")
        let projectB = makeProject(name: "Project B", path: "/tmp/project-b")

        aiUsageStore.saveExternalSummary(
            makeExternalSummary(
                project: projectA,
                externalSessionID: "a-before",
                firstSeenAt: claimDate.addingTimeInterval(60),
                totalTokens: 120
            )
        )
        aiUsageStore.saveExternalSummary(
            makeExternalSummary(
                project: projectB,
                externalSessionID: "b-history",
                firstSeenAt: claimDate.addingTimeInterval(-600),
                totalTokens: 900
            )
        )
        aiUsageStore.saveExternalSummary(
            makeExternalSummary(
                project: projectB,
                externalSessionID: "b-after",
                firstSeenAt: claimDate.addingTimeInterval(300),
                totalTokens: 80
            )
        )

        seedLiveSession(
            terminalID: UUID(),
            project: projectB,
            externalSessionID: "b-live-before-claim",
            totalTokens: 1_100,
            baselineTotalTokens: 1_000,
            startedAt: claimDate.addingTimeInterval(-60)
        )
        seedLiveSession(
            terminalID: UUID(),
            project: projectB,
            externalSessionID: "b-live-after-claim",
            totalTokens: 250,
            baselineTotalTokens: 200,
            startedAt: claimDate.addingTimeInterval(30)
        )

        XCTAssertEqual(
            store.normalizedTokenTotalsForPet([projectA, projectB], claimedAt: claimDate),
            [
                projectA.id: 120,
                projectB.id: 130,
            ]
        )
        XCTAssertEqual(
            store.totalNormalizedTokensForPet([projectA, projectB], claimedAt: claimDate),
            250
        )

        let stats = store.petStatsSinceClaimedAt(claimDate, projects: [projectA, projectB])
        XCTAssertEqual(
            stats,
            AIStatsStore.computePetStats(
                from: aiUsageStore.indexedSessions(
                    since: claimDate,
                    projectIDs: Set([projectA.id, projectB.id])
                )
            )
        )
    }

    private func makeStore(aiUsageStore: AIUsageStore? = nil) -> AIStatsStore {
        AIStatsStore(aiUsageStore: aiUsageStore ?? AIUsageStore(databaseURL: databaseURL))
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

    private func seedLiveSession(
        terminalID: UUID,
        project: Project,
        externalSessionID: String,
        totalTokens: Int,
        baselineTotalTokens: Int,
        startedAt: Date = Date()
    ) {
        let sessionStore = AISessionStore.shared
        sessionStore.registerExpectedLogicalSession(
            terminalID: terminalID,
            tool: "codex",
            aiSessionID: externalSessionID
        )
        _ = sessionStore.apply(
            AIHookEvent(
                kind: .promptSubmitted,
                terminalID: terminalID,
                terminalInstanceID: terminalID.uuidString,
                projectID: project.id,
                projectName: project.name,
                sessionTitle: externalSessionID,
                tool: "codex",
                aiSessionID: nil,
                model: "gpt-5.4",
                totalTokens: nil,
                updatedAt: startedAt.timeIntervalSince1970,
                metadata: nil
            )
        )

        XCTAssertTrue(
            sessionStore.applyRuntimeSnapshot(
                terminalID: terminalID,
                snapshot: AIRuntimeContextSnapshot(
                    tool: "codex",
                    externalSessionID: externalSessionID,
                    model: "gpt-5.4",
                    inputTokens: baselineTotalTokens,
                    outputTokens: 0,
                    cachedInputTokens: 0,
                    totalTokens: baselineTotalTokens,
                    updatedAt: startedAt.addingTimeInterval(1).timeIntervalSince1970,
                    responseState: .responding,
                    wasInterrupted: false,
                    hasCompletedTurn: false,
                    sessionOrigin: .restored,
                    source: .probe
                )
            )
        )
        if totalTokens > baselineTotalTokens {
            XCTAssertTrue(
                sessionStore.applyRuntimeSnapshot(
                    terminalID: terminalID,
                    snapshot: AIRuntimeContextSnapshot(
                        tool: "codex",
                        externalSessionID: externalSessionID,
                        model: "gpt-5.4",
                        inputTokens: totalTokens,
                        outputTokens: 0,
                        cachedInputTokens: 0,
                        totalTokens: totalTokens,
                        updatedAt: startedAt.addingTimeInterval(2).timeIntervalSince1970,
                        responseState: .responding,
                        wasInterrupted: false,
                        hasCompletedTurn: false,
                        sessionOrigin: .restored,
                        source: .probe
                    )
                )
            )
        }
    }

    private func makeExternalSummary(
        project: Project,
        externalSessionID: String,
        firstSeenAt: Date,
        totalTokens: Int
    ) -> AIExternalFileSummary {
        let lastSeenAt = firstSeenAt.addingTimeInterval(120)
        return AIExternalFileSummary(
            source: "codex",
            filePath: "\(project.path)-\(externalSessionID).jsonl",
            fileModifiedAt: lastSeenAt.timeIntervalSince1970,
            projectPath: project.path,
            usageBuckets: [
                AIUsageBucket(
                    source: "codex",
                    sessionKey: externalSessionID,
                    externalSessionID: externalSessionID,
                    sessionTitle: externalSessionID,
                    model: "gpt-5.4",
                    projectID: project.id,
                    projectName: project.name,
                    bucketStart: firstSeenAt,
                    bucketEnd: lastSeenAt,
                    inputTokens: totalTokens,
                    outputTokens: 0,
                    totalTokens: totalTokens,
                    cachedInputTokens: 0,
                    requestCount: 1,
                    activeDurationSeconds: 120,
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt
                )
            ],
            sessions: [
                AISessionSummary(
                    sessionID: UUID(),
                    externalSessionID: externalSessionID,
                    projectID: project.id,
                    projectName: project.name,
                    sessionTitle: externalSessionID,
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt,
                    lastTool: "codex",
                    lastModel: "gpt-5.4",
                    requestCount: 1,
                    totalInputTokens: totalTokens,
                    totalOutputTokens: 0,
                    totalTokens: totalTokens,
                    cachedInputTokens: 0,
                    maxContextUsagePercent: nil,
                    activeDurationSeconds: 120,
                    todayTokens: totalTokens,
                    todayCachedInputTokens: 0
                )
            ],
            dayUsage: [],
            timeBuckets: []
        )
    }
}
