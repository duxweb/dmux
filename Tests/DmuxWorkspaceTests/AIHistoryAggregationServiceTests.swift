import XCTest
@testable import DmuxWorkspace

final class AIHistoryAggregationServiceTests: XCTestCase {
    func testBuildExternalFileSummaryAndProjectSummaryMergeFileSummaries() {
        let service = AIHistoryAggregationService()
        let project = Project(
            id: UUID(),
            name: "Workspace",
            path: "/tmp/workspace",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )

        let now = Date()
        let earlier = now.addingTimeInterval(-86_400)
        let today = Calendar.autoupdatingCurrent.startOfDay(for: now)

        let claudeParse = AIHistoryParseResult(
            entries: [
                AIHistoryUsageEntry(
                    key: AIHistorySessionKey(source: "claude", sessionID: "claude-1"),
                    projectName: project.name,
                    timestamp: earlier,
                    model: "claude-sonnet",
                    inputTokens: 100,
                    outputTokens: 50,
                    cachedInputTokens: 10,
                    reasoningOutputTokens: 0
                )
            ],
            events: [
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "claude", sessionID: "claude-1"),
                    projectName: project.name,
                    timestamp: earlier,
                    role: .user
                ),
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "claude", sessionID: "claude-1"),
                    projectName: project.name,
                    timestamp: earlier.addingTimeInterval(60),
                    role: .assistant
                )
            ],
            metadataByKey: [
                AIHistorySessionKey(source: "claude", sessionID: "claude-1"): AIHistorySessionMetadata(
                    key: AIHistorySessionKey(source: "claude", sessionID: "claude-1"),
                    externalSessionID: "claude-1",
                    sessionTitle: "Claude Session",
                    model: "claude-sonnet"
                )
            ]
        )

        let codexParse = AIHistoryParseResult(
            entries: [
                AIHistoryUsageEntry(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now,
                    model: "gpt-5.4",
                    inputTokens: 40,
                    outputTokens: 20,
                    cachedInputTokens: 0,
                    reasoningOutputTokens: 5
                )
            ],
            events: [
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now,
                    role: .user
                ),
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now.addingTimeInterval(45),
                    role: .assistant
                )
            ],
            metadataByKey: [
                AIHistorySessionKey(source: "codex", sessionID: "codex-1"): AIHistorySessionMetadata(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    externalSessionID: "codex-1",
                    sessionTitle: "Codex Session",
                    model: "gpt-5.4"
                )
            ]
        )

        let claudeSummary = service.buildExternalFileSummary(
            source: "claude",
            filePath: "/tmp/claude.jsonl",
            fileModifiedAt: now.timeIntervalSince1970,
            project: project,
            parseResult: claudeParse
        )
        let codexSummary = service.buildExternalFileSummary(
            source: "codex",
            filePath: "/tmp/codex.jsonl",
            fileModifiedAt: now.timeIntervalSince1970,
            project: project,
            parseResult: codexParse
        )

        let merged = service.buildProjectSummary(
            project: project,
            fileSummaries: [claudeSummary, codexSummary]
        )

        XCTAssertEqual(merged.sessions.count, 2)
        XCTAssertEqual(merged.sessions.first?.lastTool, "codex")
        XCTAssertEqual(merged.sessions.first?.totalTokens, 65)
        XCTAssertEqual(merged.toolBreakdown.map(\.key), ["claude", "codex"])
        XCTAssertEqual(merged.toolBreakdown.map(\.totalTokens), [150, 65])
        XCTAssertEqual(merged.modelBreakdown.map(\.key), ["claude-sonnet", "gpt-5.4"])
        XCTAssertEqual(merged.heatmap.count, Set([Calendar.autoupdatingCurrent.startOfDay(for: earlier), today]).count)
        XCTAssertEqual(merged.todayTimeBuckets.reduce(0) { $0 + $1.totalTokens }, 65)
        XCTAssertEqual(merged.sessions.first?.lastTool, "codex")
    }

    func testRequestCountsFollowUserMessagesNotUsageEntries() {
        let service = AIHistoryAggregationService()
        let project = Project(
            id: UUID(),
            name: "Workspace",
            path: "/tmp/workspace",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )

        let now = Date()
        let parseResult = AIHistoryParseResult(
            entries: [
                AIHistoryUsageEntry(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now.addingTimeInterval(5),
                    model: "gpt-5.4",
                    inputTokens: 10,
                    outputTokens: 4,
                    cachedInputTokens: 6,
                    reasoningOutputTokens: 2
                ),
                AIHistoryUsageEntry(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now.addingTimeInterval(15),
                    model: "gpt-5.4",
                    inputTokens: 8,
                    outputTokens: 3,
                    cachedInputTokens: 2,
                    reasoningOutputTokens: 1
                )
            ],
            events: [
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now,
                    role: .user
                ),
                AIHistorySessionEvent(
                    key: AIHistorySessionKey(source: "codex", sessionID: "codex-1"),
                    projectName: project.name,
                    timestamp: now.addingTimeInterval(20),
                    role: .assistant
                )
            ],
            metadataByKey: [:]
        )

        let summary = service.buildProjectSummary(project: project, parseResults: [parseResult])
        let session = summary.sessions.first
        XCTAssertEqual(session?.requestCount, 1)
        XCTAssertEqual(session?.totalInputTokens, 18)
        XCTAssertEqual(session?.totalOutputTokens, 7)
        XCTAssertEqual(session?.totalTokens, 28)
        XCTAssertEqual(summary.heatmap.first?.requestCount, 1)
        XCTAssertEqual(summary.heatmap.first?.totalTokens, 28)
        XCTAssertEqual(summary.todayTimeBuckets.reduce(0) { $0 + $1.requestCount }, 1)
        XCTAssertEqual(summary.todayTimeBuckets.reduce(0) { $0 + $1.totalTokens }, 28)
    }

    func testDuplicateLogicalSessionsAcrossFilesAccumulateSessionTotals() {
        let service = AIHistoryAggregationService()
        let project = Project(
            id: UUID(),
            name: "Workspace",
            path: "/tmp/workspace",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )

        let now = Date()
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour], from: now)
        let bucketStart = Calendar.autoupdatingCurrent.date(from: components) ?? now
        let bucketEnd = bucketStart.addingTimeInterval(3600)
        let sessionA = AISessionSummary(
            sessionID: UUID(),
            externalSessionID: "claude-1",
            projectID: project.id,
            projectName: project.name,
            sessionTitle: "Claude Session",
            firstSeenAt: now.addingTimeInterval(-120),
            lastSeenAt: now.addingTimeInterval(-60),
            lastTool: "claude",
            lastModel: "claude-sonnet-4-6",
            requestCount: 2,
            totalInputTokens: 100,
            totalOutputTokens: 50,
            totalTokens: 150,
            cachedInputTokens: 20,
            maxContextUsagePercent: nil,
            activeDurationSeconds: 60,
            todayTokens: 150,
            todayCachedInputTokens: 20
        )
        let sessionB = AISessionSummary(
            sessionID: UUID(),
            externalSessionID: "claude-1",
            projectID: project.id,
            projectName: project.name,
            sessionTitle: "Claude Session Duplicate",
            firstSeenAt: now.addingTimeInterval(-50),
            lastSeenAt: now,
            lastTool: "claude",
            lastModel: "claude-sonnet-4-6",
            requestCount: 1,
            totalInputTokens: 40,
            totalOutputTokens: 10,
            totalTokens: 50,
            cachedInputTokens: 5,
            maxContextUsagePercent: nil,
            activeDurationSeconds: 30,
            todayTokens: 50,
            todayCachedInputTokens: 5
        )

        let summaryA = AIExternalFileSummary(
            source: "claude",
            filePath: "/tmp/a.jsonl",
            fileModifiedAt: now.timeIntervalSince1970,
            projectPath: project.path,
            usageBuckets: [
                AIUsageBucket(
                    source: "claude",
                    sessionKey: "claude-1",
                    externalSessionID: "claude-1",
                    sessionTitle: "Claude Session",
                    model: "claude-sonnet-4-6",
                    projectID: project.id,
                    projectName: project.name,
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    cachedInputTokens: 20,
                    requestCount: 2,
                    activeDurationSeconds: 60,
                    firstSeenAt: sessionA.firstSeenAt,
                    lastSeenAt: sessionA.lastSeenAt
                )
            ],
            sessions: [sessionA],
            dayUsage: [
                AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: now), totalTokens: 150, cachedInputTokens: 20, requestCount: 2)
            ],
            timeBuckets: [
                AITimeBucket(start: now, end: now.addingTimeInterval(3600), totalTokens: 150, cachedInputTokens: 20, requestCount: 2)
            ]
        )
        let summaryB = AIExternalFileSummary(
            source: "claude",
            filePath: "/tmp/b.jsonl",
            fileModifiedAt: now.timeIntervalSince1970,
            projectPath: project.path,
            usageBuckets: [
                AIUsageBucket(
                    source: "claude",
                    sessionKey: "claude-1",
                    externalSessionID: "claude-1",
                    sessionTitle: "Claude Session Duplicate",
                    model: "claude-sonnet-4-6",
                    projectID: project.id,
                    projectName: project.name,
                    bucketStart: bucketStart,
                    bucketEnd: bucketEnd,
                    inputTokens: 40,
                    outputTokens: 10,
                    totalTokens: 50,
                    cachedInputTokens: 5,
                    requestCount: 1,
                    activeDurationSeconds: 30,
                    firstSeenAt: sessionB.firstSeenAt,
                    lastSeenAt: sessionB.lastSeenAt
                )
            ],
            sessions: [sessionB],
            dayUsage: [
                AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: now), totalTokens: 50, cachedInputTokens: 5, requestCount: 1)
            ],
            timeBuckets: [
                AITimeBucket(start: now, end: now.addingTimeInterval(3600), totalTokens: 50, cachedInputTokens: 5, requestCount: 1)
            ]
        )

        let merged = service.buildProjectSummary(project: project, fileSummaries: [summaryA, summaryB])

        XCTAssertEqual(merged.sessions.count, 1)
        XCTAssertEqual(merged.sessions.first?.requestCount, 3)
        XCTAssertEqual(merged.sessions.first?.totalInputTokens, 140)
        XCTAssertEqual(merged.sessions.first?.totalOutputTokens, 60)
        XCTAssertEqual(merged.sessions.first?.totalTokens, 200)
        XCTAssertEqual(merged.sessions.first?.cachedInputTokens, 25)
        XCTAssertEqual(merged.sessions.first?.todayTokens, 200)
        XCTAssertEqual(merged.sessions.first?.todayCachedInputTokens, 25)
        XCTAssertEqual(merged.heatmap.reduce(0) { $0 + $1.totalTokens }, 200)
        XCTAssertEqual(merged.heatmap.reduce(0) { $0 + $1.cachedInputTokens }, 25)
        XCTAssertEqual(merged.todayTimeBuckets.reduce(0) { $0 + $1.totalTokens }, 200)
        XCTAssertEqual(merged.todayTimeBuckets.reduce(0) { $0 + $1.cachedInputTokens }, 25)
    }

    func testBuildProjectSummaryClampsCorruptedActiveDurationToWallClock() {
        let service = AIHistoryAggregationService()
        let project = Project(
            id: UUID(),
            name: "Workspace",
            path: "/tmp/workspace",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
        let firstSeenAt = Date(timeIntervalSince1970: 1_777_000_000)
        let lastSeenAt = firstSeenAt.addingTimeInterval(120)

        let summary = service.buildProjectSummary(
            project: project,
            fileSummaries: [
                AIExternalFileSummary(
                    source: "codex",
                    filePath: "/tmp/corrupted.jsonl",
                    fileModifiedAt: lastSeenAt.timeIntervalSince1970,
                    projectPath: project.path,
                    usageBuckets: [
                        AIUsageBucket(
                            source: "codex",
                            sessionKey: "corrupted-session",
                            externalSessionID: "corrupted-session",
                            sessionTitle: "Corrupted Session",
                            model: "gpt-5.4",
                            projectID: project.id,
                            projectName: project.name,
                            bucketStart: firstSeenAt,
                            bucketEnd: lastSeenAt,
                            inputTokens: 100,
                            outputTokens: 50,
                            totalTokens: 150,
                            cachedInputTokens: 0,
                            requestCount: 2,
                            activeDurationSeconds: Int.max,
                            firstSeenAt: firstSeenAt,
                            lastSeenAt: lastSeenAt
                        )
                    ],
                    sessions: [],
                    dayUsage: [],
                    timeBuckets: []
                )
            ]
        )

        XCTAssertEqual(summary.sessions.count, 1)
        XCTAssertEqual(summary.sessions.first?.activeDurationSeconds, 120)
    }

    func testBuildProjectSummarySaturatesCorruptedTokenAggregates() {
        let service = AIHistoryAggregationService()
        let project = Project(
            id: UUID(),
            name: "Workspace",
            path: "/tmp/workspace",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
        let bucketStart = Calendar.autoupdatingCurrent.startOfDay(for: Date()).addingTimeInterval(1800)
        let bucketEnd = bucketStart.addingTimeInterval(1800)

        let summary = service.buildProjectSummary(
            project: project,
            fileSummaries: [
                AIExternalFileSummary(
                    source: "codex",
                    filePath: "/tmp/corrupted-totals.jsonl",
                    fileModifiedAt: bucketEnd.timeIntervalSince1970,
                    projectPath: project.path,
                    usageBuckets: [
                        AIUsageBucket(
                            source: "codex",
                            sessionKey: "corrupted-session",
                            externalSessionID: "corrupted-session",
                            sessionTitle: "Corrupted Session",
                            model: "gpt-5.4",
                            projectID: project.id,
                            projectName: project.name,
                            bucketStart: bucketStart,
                            bucketEnd: bucketEnd,
                            inputTokens: Int.max,
                            outputTokens: Int.max,
                            totalTokens: Int.max,
                            cachedInputTokens: Int.max,
                            requestCount: Int.max,
                            activeDurationSeconds: 60,
                            firstSeenAt: bucketStart,
                            lastSeenAt: bucketEnd
                        ),
                        AIUsageBucket(
                            source: "codex",
                            sessionKey: "corrupted-session",
                            externalSessionID: "corrupted-session",
                            sessionTitle: "Corrupted Session",
                            model: "gpt-5.4",
                            projectID: project.id,
                            projectName: project.name,
                            bucketStart: bucketStart,
                            bucketEnd: bucketEnd,
                            inputTokens: 1,
                            outputTokens: 1,
                            totalTokens: 1,
                            cachedInputTokens: 1,
                            requestCount: 1,
                            activeDurationSeconds: 60,
                            firstSeenAt: bucketStart,
                            lastSeenAt: bucketEnd
                        )
                    ],
                    sessions: [],
                    dayUsage: [],
                    timeBuckets: []
                )
            ]
        )

        XCTAssertEqual(summary.sessions.count, 1)
        XCTAssertEqual(summary.sessions.first?.totalInputTokens, Int.max)
        XCTAssertEqual(summary.sessions.first?.totalOutputTokens, Int.max)
        XCTAssertEqual(summary.sessions.first?.totalTokens, Int.max)
        XCTAssertEqual(summary.sessions.first?.cachedInputTokens, Int.max)
        XCTAssertEqual(summary.sessions.first?.requestCount, Int.max)
        XCTAssertEqual(summary.heatmap.first?.totalTokens, Int.max)
        XCTAssertEqual(summary.heatmap.first?.cachedInputTokens, Int.max)
        XCTAssertEqual(summary.heatmap.first?.requestCount, Int.max)
        XCTAssertEqual(summary.todayTimeBuckets.reduce(0) { max($0, $1.totalTokens) }, Int.max)
        XCTAssertEqual(summary.todayTimeBuckets.reduce(0) { max($0, $1.cachedInputTokens) }, Int.max)
        XCTAssertEqual(summary.todayTimeBuckets.reduce(0) { max($0, $1.requestCount) }, Int.max)
        XCTAssertEqual(summary.toolBreakdown.first?.totalTokens, Int.max)
        XCTAssertEqual(summary.toolBreakdown.first?.cachedInputTokens, Int.max)
        XCTAssertEqual(summary.toolBreakdown.first?.requestCount, Int.max)
    }
}
