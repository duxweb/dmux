import XCTest
@testable import DmuxWorkspace

@MainActor
final class AIStatsStoreMetricsTests: XCTestCase {
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
        let store = AIStatsStore()
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

        XCTAssertEqual(store.titlebarTodayLevelTokens(), 2_920_000)
    }
}
