import XCTest
import SQLite3
@testable import DmuxWorkspace

final class AIUsageStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmux-ai-usage-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testIndexedProjectSnapshotIsDerivedFromNormalizedHistoryTables() {
        let store = makeStore()
        let projectID = UUID()
        let projectPath = "/tmp/normalized-project"
        let indexedAt = Date(timeIntervalSince1970: 1_713_690_123)

        store.deleteExternalSummaries(projectPath: projectPath)
        store.deleteProjectIndexState(projectID: projectID)

        let summary = AIExternalFileSummary(
            source: "claude",
            filePath: "/tmp/claude.jsonl",
            fileModifiedAt: 1_713_690_000,
            projectPath: projectPath,
            usageBuckets: [
                makeUsageBucket(
                    source: "claude",
                    sessionKey: "claude-1",
                    externalSessionID: "claude-1",
                    projectID: projectID,
                    projectName: "Normalized Project",
                    sessionTitle: "Fix bug",
                    model: "claude-sonnet-4-6",
                    totalTokens: 150,
                    cachedInputTokens: 30,
                    requestCount: 2,
                    activeDurationSeconds: 60
                )
            ],
            sessions: [
                AISessionSummary(
                    sessionID: UUID(),
                    externalSessionID: "claude-1",
                    projectID: projectID,
                    projectName: "Normalized Project",
                    sessionTitle: "Fix bug",
                    firstSeenAt: Date(timeIntervalSince1970: 1_713_600_000),
                    lastSeenAt: Date(timeIntervalSince1970: 1_713_600_100),
                    lastTool: "claude",
                    lastModel: "claude-sonnet-4-6",
                    requestCount: 2,
                    totalInputTokens: 100,
                    totalOutputTokens: 50,
                    totalTokens: 150,
                    cachedInputTokens: 30,
                    maxContextUsagePercent: nil,
                    activeDurationSeconds: 60,
                    todayTokens: 150,
                    todayCachedInputTokens: 30
                )
            ],
            dayUsage: [
                AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: Date()), totalTokens: 150, cachedInputTokens: 30, requestCount: 2)
            ],
            timeBuckets: [
                AITimeBucket(
                    start: Calendar.autoupdatingCurrent.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date(),
                    end: Calendar.autoupdatingCurrent.date(bySettingHour: 11, minute: 0, second: 0, of: Date()) ?? Date(),
                    totalTokens: 150,
                    cachedInputTokens: 30,
                    requestCount: 2
                )
            ]
        )
        store.saveExternalSummary(summary)
        store.saveProjectIndexState(for:
            AIIndexedProjectSnapshot(
                projectID: projectID,
                projectName: "Normalized Project",
                projectSummary: AIProjectUsageSummary(
                    projectID: projectID,
                    projectName: "Normalized Project",
                    currentSessionTokens: 0,
                    currentSessionCachedInputTokens: 0,
                    projectTotalTokens: 150,
                    projectCachedInputTokens: 30,
                    todayTotalTokens: 150,
                    todayCachedInputTokens: 30,
                    currentTool: nil,
                    currentModel: nil,
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: nil
                ),
                sessions: summary.sessions,
                heatmap: summary.dayUsage,
                todayTimeBuckets: summary.timeBuckets,
                toolBreakdown: [],
                modelBreakdown: [],
                indexedAt: indexedAt
            ),
            projectPath: projectPath
        )

        let snapshot = store.indexedProjectSnapshot(projectID: projectID)
        XCTAssertEqual(snapshot?.projectID, projectID)
        XCTAssertEqual(snapshot?.projectSummary.projectTotalTokens, 150)
        XCTAssertEqual(snapshot?.projectSummary.projectCachedInputTokens, 30)
        XCTAssertEqual(snapshot?.projectSummary.todayTotalTokens, 150)
        XCTAssertEqual(snapshot?.projectSummary.todayCachedInputTokens, 30)
        XCTAssertEqual(snapshot?.sessions.count, 1)
        XCTAssertEqual(snapshot?.toolBreakdown.first?.key, "claude")
        XCTAssertEqual(snapshot?.toolBreakdown.first?.totalTokens, 150)
        XCTAssertEqual(snapshot?.toolBreakdown.first?.cachedInputTokens, 30)
        XCTAssertEqual(snapshot?.indexedAt.timeIntervalSince1970, indexedAt.timeIntervalSince1970)
    }

    func testStoredExternalSummaryIsScopedByProjectPathForSharedFilePath() {
        let store = makeStore()
        let sharedFilePath = "/tmp/shared-opencode.db"
        let modifiedAt = 1_713_690_000.0
        let projectA = "/tmp/project-a"
        let projectB = "/tmp/project-b"

        store.deleteExternalSummaries(projectPath: projectA)
        store.deleteExternalSummaries(projectPath: projectB)

        let summaryA = AIExternalFileSummary(
            source: "opencode",
            filePath: sharedFilePath,
            fileModifiedAt: modifiedAt,
            projectPath: projectA,
            usageBuckets: [
                makeUsageBucket(
                    source: "opencode",
                    sessionKey: "A",
                    externalSessionID: "A",
                    projectID: UUID(),
                    projectName: projectA,
                    sessionTitle: "A",
                    model: "gpt-4.1",
                    totalTokens: 111,
                    requestCount: 1,
                    activeDurationSeconds: 10
                )
            ],
            sessions: [
                makeSessionSummary(projectPath: projectA, title: "A", totalTokens: 111)
            ],
            dayUsage: [
                AIHeatmapDay(day: Date(timeIntervalSince1970: 1_713_600_000), totalTokens: 111, requestCount: 1)
            ],
            timeBuckets: []
        )
        let summaryB = AIExternalFileSummary(
            source: "opencode",
            filePath: sharedFilePath,
            fileModifiedAt: modifiedAt,
            projectPath: projectB,
            usageBuckets: [
                makeUsageBucket(
                    source: "opencode",
                    sessionKey: "B",
                    externalSessionID: "B",
                    projectID: UUID(),
                    projectName: projectB,
                    sessionTitle: "B",
                    model: "gpt-4.1",
                    totalTokens: 222,
                    requestCount: 1,
                    activeDurationSeconds: 10
                )
            ],
            sessions: [
                makeSessionSummary(projectPath: projectB, title: "B", totalTokens: 222)
            ],
            dayUsage: [
                AIHeatmapDay(day: Date(timeIntervalSince1970: 1_713_600_000), totalTokens: 222, requestCount: 1)
            ],
            timeBuckets: []
        )

        store.saveExternalSummary(summaryA)
        store.saveExternalSummary(summaryB)

        let storedA = store.storedExternalSummary(
            source: "opencode",
            filePath: sharedFilePath,
            projectPath: projectA,
            modifiedAt: modifiedAt
        )
        let storedB = store.storedExternalSummary(
            source: "opencode",
            filePath: sharedFilePath,
            projectPath: projectB,
            modifiedAt: modifiedAt
        )

        XCTAssertEqual(storedA?.projectPath, projectA)
        XCTAssertEqual(storedA?.sessions.first?.totalTokens, 111)
        XCTAssertEqual(storedB?.projectPath, projectB)
        XCTAssertEqual(storedB?.sessions.first?.totalTokens, 222)
    }

    func testLegacyTablesDoNotBreakInitializationOrNormalizedWrites() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        guard let db else {
            return XCTFail("failed to open sqlite database")
        }
        defer { sqlite3_close(db) }

        let legacyStatements = [
            """
            CREATE TABLE IF NOT EXISTS ai_external_file_cache (
                source TEXT NOT NULL,
                file_path TEXT PRIMARY KEY,
                file_modified_at REAL NOT NULL,
                project_path TEXT NOT NULL,
                payload_json TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS ai_indexed_project_snapshot (
                project_id TEXT PRIMARY KEY,
                indexed_at REAL NOT NULL,
                payload_json TEXT NOT NULL
            );
            """
        ]

        for statement in legacyStatements {
            XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK)
        }

        let store = makeStore()
        let projectID = UUID()
        let projectPath = "/tmp/legacy-upgrade"
        let summary = AIExternalFileSummary(
            source: "claude",
            filePath: "/tmp/legacy-claude.jsonl",
            fileModifiedAt: 1_713_690_000,
            projectPath: projectPath,
            usageBuckets: [
                makeUsageBucket(
                    source: "claude",
                    sessionKey: "legacy",
                    externalSessionID: "legacy",
                    projectID: projectID,
                    projectName: "Legacy Upgrade",
                    sessionTitle: "Legacy Session",
                    model: "claude-sonnet-4-6",
                    totalTokens: 70,
                    requestCount: 1,
                    activeDurationSeconds: 60
                )
            ],
            sessions: [
                AISessionSummary(
                    sessionID: UUID(),
                    externalSessionID: "legacy",
                    projectID: projectID,
                    projectName: "Legacy Upgrade",
                    sessionTitle: "Legacy Session",
                    firstSeenAt: Date(timeIntervalSince1970: 1_713_600_000),
                    lastSeenAt: Date(timeIntervalSince1970: 1_713_600_060),
                    lastTool: "claude",
                    lastModel: "claude-sonnet-4-6",
                    requestCount: 1,
                    totalInputTokens: 50,
                    totalOutputTokens: 20,
                    totalTokens: 70,
                    maxContextUsagePercent: nil,
                    activeDurationSeconds: 60,
                    todayTokens: 70
                )
            ],
            dayUsage: [
                AIHeatmapDay(day: Calendar.autoupdatingCurrent.startOfDay(for: Date()), totalTokens: 70, requestCount: 1)
            ],
            timeBuckets: []
        )

        store.saveExternalSummary(summary)
        let stored = store.storedExternalSummary(
            source: "claude",
            filePath: summary.filePath,
            projectPath: projectPath,
            modifiedAt: summary.fileModifiedAt
        )

        XCTAssertEqual(stored?.projectPath, projectPath)
        XCTAssertEqual(stored?.sessions.first?.totalTokens, 70)
    }

    func testExternalSummaryCheckpointRoundTrips() {
        let store = makeStore()
        let projectPath = "/tmp/checkpoint-project"
        let summary = AIExternalFileSummary(
            source: "claude",
            filePath: "/tmp/checkpoint.jsonl",
            fileModifiedAt: 1_713_690_000,
            projectPath: projectPath,
            usageBuckets: [
                makeUsageBucket(
                    source: "claude",
                    sessionKey: "session-1",
                    externalSessionID: "session-1",
                    projectID: UUID(),
                    projectName: projectPath,
                    sessionTitle: "Checkpoint",
                    model: "claude-sonnet-4-6",
                    inputTokens: 111,
                    outputTokens: 210,
                    totalTokens: 321,
                    requestCount: 2,
                    activeDurationSeconds: 60
                )
            ],
            sessions: [
                makeSessionSummary(projectPath: projectPath, title: "Checkpoint", totalTokens: 321)
            ],
            dayUsage: [],
            timeBuckets: []
        )
        let checkpoint = AIExternalFileCheckpoint(
            source: "claude",
            filePath: summary.filePath,
            projectPath: projectPath,
            fileModifiedAt: summary.fileModifiedAt,
            fileSize: 4096,
            lastOffset: 3072,
            lastIndexedAt: Date(timeIntervalSince1970: 1_713_690_123),
            payload: AIExternalFileCheckpointPayload(
                sessionKey: "session-1",
                externalSessionID: "session-1",
                sessionTitle: "Checkpoint",
                lastModel: "claude-sonnet-4-6",
                modelTotalTokensByName: ["claude-sonnet-4-6": 321],
                firstSeenAt: Date(timeIntervalSince1970: 1_713_600_000),
                lastSeenAt: Date(timeIntervalSince1970: 1_713_600_060),
                requestCount: 2,
                totalInputTokens: 111,
                totalOutputTokens: 210,
                totalTokens: 321,
                todayTokens: 321,
                activeDurationSeconds: 60,
                waitingForFirstResponse: false,
                pendingTurnStartAt: nil,
                pendingTurnEndAt: nil
            )
        )

        store.saveExternalSummary(summary, checkpoint: checkpoint)
        let storedCheckpoint = store.externalFileCheckpoint(
            source: "claude",
            filePath: summary.filePath,
            projectPath: projectPath
        )
        let storedSummaryWithoutModifiedAt = store.storedExternalSummary(
            source: "claude",
            filePath: summary.filePath,
            projectPath: projectPath
        )

        XCTAssertEqual(storedCheckpoint?.fileSize, 4096)
        XCTAssertEqual(storedCheckpoint?.lastOffset, 3072)
        XCTAssertEqual(storedCheckpoint?.payload?.sessionKey, "session-1")
        XCTAssertEqual(storedCheckpoint?.payload?.modelTotalTokensByName["claude-sonnet-4-6"], 321)
        XCTAssertEqual(storedSummaryWithoutModifiedAt?.sessions.first?.totalTokens, 321)
    }

    func testIndexedSessionsSinceClaimKeepsPostCutoffBucketsFromExistingSessions() {
        let store = makeStore()
        let projectID = UUID()
        let projectPath = "/tmp/pet-cutoff-project"
        let cutoff = Date(timeIntervalSince1970: 1_713_700_000)

        let summary = AIExternalFileSummary(
            source: "codex",
            filePath: "/tmp/pet-cutoff.jsonl",
            fileModifiedAt: 1_713_700_100,
            projectPath: projectPath,
            usageBuckets: [
                AIUsageBucket(
                    source: "codex",
                    sessionKey: "before-cutoff",
                    externalSessionID: "before-cutoff",
                    sessionTitle: "Old Session",
                    model: "gpt-5.4",
                    projectID: projectID,
                    projectName: "Pet Cutoff",
                    bucketStart: cutoff.addingTimeInterval(-1_800),
                    bucketEnd: cutoff,
                    inputTokens: 30,
                    outputTokens: 20,
                    totalTokens: 50,
                    cachedInputTokens: 0,
                    requestCount: 1,
                    activeDurationSeconds: 0,
                    firstSeenAt: cutoff.addingTimeInterval(-3_600),
                    lastSeenAt: cutoff.addingTimeInterval(120)
                ),
                AIUsageBucket(
                    source: "codex",
                    sessionKey: "before-cutoff",
                    externalSessionID: "before-cutoff",
                    sessionTitle: "Old Session",
                    model: "gpt-5.4",
                    projectID: projectID,
                    projectName: "Pet Cutoff",
                    bucketStart: cutoff.addingTimeInterval(60),
                    bucketEnd: cutoff.addingTimeInterval(120),
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    cachedInputTokens: 0,
                    requestCount: 2,
                    activeDurationSeconds: 120,
                    firstSeenAt: cutoff.addingTimeInterval(-3600),
                    lastSeenAt: cutoff.addingTimeInterval(120)
                ),
                AIUsageBucket(
                    source: "codex",
                    sessionKey: "after-cutoff",
                    externalSessionID: "after-cutoff",
                    sessionTitle: "Fresh Session",
                    model: "gpt-5.4",
                    projectID: projectID,
                    projectName: "Pet Cutoff",
                    bucketStart: cutoff.addingTimeInterval(180),
                    bucketEnd: cutoff.addingTimeInterval(240),
                    inputTokens: 60,
                    outputTokens: 40,
                    totalTokens: 100,
                    cachedInputTokens: 0,
                    requestCount: 1,
                    activeDurationSeconds: 60,
                    firstSeenAt: cutoff.addingTimeInterval(180),
                    lastSeenAt: cutoff.addingTimeInterval(240)
                ),
            ],
            sessions: [
                AISessionSummary(
                    sessionID: UUID(),
                    externalSessionID: "before-cutoff",
                    projectID: projectID,
                    projectName: "Pet Cutoff",
                    sessionTitle: "Old Session",
                    firstSeenAt: cutoff.addingTimeInterval(-3600),
                    lastSeenAt: cutoff.addingTimeInterval(120),
                    lastTool: "codex",
                    lastModel: "gpt-5.4",
                    requestCount: 2,
                    totalInputTokens: 100,
                    totalOutputTokens: 50,
                    totalTokens: 150,
                    cachedInputTokens: 0,
                    maxContextUsagePercent: nil,
                    activeDurationSeconds: 120,
                    todayTokens: 150,
                    todayCachedInputTokens: 0
                ),
                AISessionSummary(
                    sessionID: UUID(),
                    externalSessionID: "after-cutoff",
                    projectID: projectID,
                    projectName: "Pet Cutoff",
                    sessionTitle: "Fresh Session",
                    firstSeenAt: cutoff.addingTimeInterval(180),
                    lastSeenAt: cutoff.addingTimeInterval(240),
                    lastTool: "codex",
                    lastModel: "gpt-5.4",
                    requestCount: 1,
                    totalInputTokens: 60,
                    totalOutputTokens: 40,
                    totalTokens: 100,
                    cachedInputTokens: 0,
                    maxContextUsagePercent: nil,
                    activeDurationSeconds: 60,
                    todayTokens: 100,
                    todayCachedInputTokens: 0
                ),
            ],
            dayUsage: [],
            timeBuckets: []
        )

        store.saveExternalSummary(summary)

        let sessions = store.indexedSessions(since: cutoff)
        XCTAssertEqual(sessions.map(\.externalSessionID), ["after-cutoff", "before-cutoff"])
        XCTAssertEqual(sessions.first?.sessionTitle, "Fresh Session")
        XCTAssertEqual(sessions.first?.totalTokens, 100)
        XCTAssertEqual(sessions.last?.sessionTitle, "Old Session")
        XCTAssertEqual(sessions.last?.totalTokens, 150)
        XCTAssertEqual(sessions.last?.requestCount, 2)
        XCTAssertEqual(sessions.last?.activeDurationSeconds, 0)
    }

    func testDatabaseConfigurationEnablesWALAndBucketStartIndex() throws {
        let store = makeStore()

        try store.withDatabase { db in
            var pragmaStatement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode;", -1, &pragmaStatement, nil), SQLITE_OK)
            defer { sqlite3_finalize(pragmaStatement) }
            XCTAssertEqual(sqlite3_step(pragmaStatement), SQLITE_ROW)
            let journalMode = sqlite3_column_text(pragmaStatement, 0).map { String(cString: $0).lowercased() }
            XCTAssertEqual(journalMode, "wal")

            var indexStatement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_ai_history_file_usage_bucket_bucket_start' LIMIT 1;",
                    -1,
                    &indexStatement,
                    nil
                ),
                SQLITE_OK
            )
            defer { sqlite3_finalize(indexStatement) }
            XCTAssertEqual(sqlite3_step(indexStatement), SQLITE_ROW)
        }
    }

    private func makeSessionSummary(projectPath: String, title: String, totalTokens: Int) -> AISessionSummary {
        let projectID = UUID()
        return AISessionSummary(
            sessionID: UUID(),
            externalSessionID: title,
            projectID: projectID,
            projectName: projectPath,
            sessionTitle: title,
            firstSeenAt: Date(timeIntervalSince1970: 1_713_600_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_713_600_100),
            lastTool: "opencode",
            lastModel: "gpt-4.1",
            requestCount: 1,
            totalInputTokens: totalTokens,
            totalOutputTokens: 0,
            totalTokens: totalTokens,
            maxContextUsagePercent: nil,
            activeDurationSeconds: 10,
            todayTokens: totalTokens
        )
    }

    private func makeUsageBucket(
        source: String,
        sessionKey: String,
        externalSessionID: String,
        projectID: UUID,
        projectName: String,
        sessionTitle: String,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int,
        cachedInputTokens: Int = 0,
        requestCount: Int,
        activeDurationSeconds: Int
    ) -> AIUsageBucket {
        let start = Calendar.autoupdatingCurrent.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        let end = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 1, to: start) ?? start
        let resolvedInput = inputTokens ?? totalTokens
        let resolvedOutput = outputTokens ?? max(0, totalTokens - resolvedInput)
        return AIUsageBucket(
            source: source,
            sessionKey: sessionKey,
            externalSessionID: externalSessionID,
            sessionTitle: sessionTitle,
            model: model,
            projectID: projectID,
            projectName: projectName,
            bucketStart: start,
            bucketEnd: end,
            inputTokens: resolvedInput,
            outputTokens: resolvedOutput,
            totalTokens: totalTokens,
            cachedInputTokens: cachedInputTokens,
            requestCount: requestCount,
            activeDurationSeconds: activeDurationSeconds,
            firstSeenAt: start,
            lastSeenAt: start.addingTimeInterval(60)
        )
    }

    private func makeStore() -> AIUsageStore {
        AIUsageStore(databaseURL: databaseURL)
    }
}
