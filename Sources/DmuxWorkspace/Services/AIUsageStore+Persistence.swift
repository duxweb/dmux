import Foundation
import SQLite3

extension AIUsageStore {
    func globalTodayNormalizedTokens(now: Date = .init()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        return (try? withDatabase { db in
            let sql = """
            SELECT COALESCE(SUM(total_tokens), 0)
            FROM ai_history_file_usage_bucket
            WHERE bucket_end > ? AND bucket_start < ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return 0
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, startOfDay.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, endOfDay.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int64(statement, 0))
        }) ?? 0
    }

    func indexedSessions(since cutoff: Date?) -> [AISessionSummary] {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        return (try? withDatabase { db in
            let sql = """
            SELECT
                session.project_id,
                session.project_name,
                session.session_title,
                session.first_seen_at,
                session.last_seen_at,
                session.last_model,
                session.external_session_id,
                session.active_duration_seconds,
                COALESCE(SUM(bucket.request_count), 0),
                COALESCE(SUM(bucket.input_tokens), 0),
                COALESCE(SUM(bucket.output_tokens), 0),
                COALESCE(SUM(bucket.total_tokens), 0),
                COALESCE(SUM(bucket.cached_input_tokens), 0),
                COALESCE(SUM(CASE WHEN bucket.bucket_end > ? AND bucket.bucket_start < ? THEN bucket.total_tokens ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN bucket.bucket_end > ? AND bucket.bucket_start < ? THEN bucket.cached_input_tokens ELSE 0 END), 0)
            FROM ai_history_file_session_link AS session
            LEFT JOIN ai_history_file_usage_bucket AS bucket
              ON bucket.source = session.source
             AND bucket.file_path = session.file_path
             AND bucket.project_path = session.project_path
             AND bucket.session_key = session.session_key
            WHERE (? IS NULL OR session.last_seen_at >= ?)
            GROUP BY
                session.source,
                session.file_path,
                session.project_path,
                session.session_key,
                session.project_id,
                session.project_name,
                session.session_title,
                session.first_seen_at,
                session.last_seen_at,
                session.last_model,
                session.external_session_id,
                session.active_duration_seconds
            ORDER BY session.last_seen_at DESC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, startOfDay.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, endOfDay.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, startOfDay.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, endOfDay.timeIntervalSince1970)
            if let cutoff {
                sqlite3_bind_double(statement, 5, cutoff.timeIntervalSince1970)
                sqlite3_bind_double(statement, 6, cutoff.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 5)
                sqlite3_bind_null(statement, 6)
            }

            var items: [AISessionSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawProjectID = sqlite3_column_text(statement, 0),
                      let projectID = UUID(uuidString: String(cString: rawProjectID)),
                      let rawProjectName = sqlite3_column_text(statement, 1),
                      let rawSessionTitle = sqlite3_column_text(statement, 2) else {
                    continue
                }

                items.append(
                    AISessionSummary(
                        sessionID: UUID(),
                        externalSessionID: sqlite3_column_text(statement, 6).map { String(cString: $0) },
                        projectID: projectID,
                        projectName: String(cString: rawProjectName),
                        sessionTitle: String(cString: rawSessionTitle),
                        firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                        lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        lastTool: nil,
                        lastModel: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                        requestCount: Int(sqlite3_column_int64(statement, 8)),
                        totalInputTokens: Int(sqlite3_column_int64(statement, 9)),
                        totalOutputTokens: Int(sqlite3_column_int64(statement, 10)),
                        totalTokens: Int(sqlite3_column_int64(statement, 11)),
                        cachedInputTokens: Int(sqlite3_column_int64(statement, 12)),
                        maxContextUsagePercent: nil,
                        activeDurationSeconds: Int(sqlite3_column_int64(statement, 7)),
                        todayTokens: Int(sqlite3_column_int64(statement, 13)),
                        todayCachedInputTokens: Int(sqlite3_column_int64(statement, 14))
                    )
                )
            }
            return items
        }) ?? []
    }

    func indexedProjectSnapshot(projectID: UUID) -> AIIndexedProjectSnapshot? {
        try? withDatabase { db in
            let sql = """
            SELECT project_name, project_path, indexed_at
            FROM ai_history_project_index_state
            WHERE project_id = ?
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, projectID.uuidString, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_ROW,
                  let rawProjectName = sqlite3_column_text(statement, 0),
                  let rawProjectPath = sqlite3_column_text(statement, 1) else {
                return nil
            }
            let project = Project(
                id: projectID,
                name: String(cString: rawProjectName),
                path: String(cString: rawProjectPath),
                shell: "/bin/zsh",
                defaultCommand: "",
                badgeText: nil,
                badgeSymbol: nil,
                badgeColorHex: nil,
                gitDefaultPushRemoteName: nil
            )
            let sources = ["claude", "codex", "gemini", "opencode"]
            let fileSummaries = sources.flatMap { storedExternalSummaries(source: $0, projectPath: project.path) }
            let summary = aggregator.buildProjectSummary(project: project, fileSummaries: fileSummaries)
            let todayTotal = summary.todayTimeBuckets.reduce(0) { $0 + $1.totalTokens }
            return AIIndexedProjectSnapshot(
                projectID: project.id,
                projectName: project.name,
                projectSummary: AIProjectUsageSummary(
                    projectID: project.id,
                    projectName: project.name,
                    currentSessionTokens: 0,
                    currentSessionCachedInputTokens: 0,
                    projectTotalTokens: summary.sessions.reduce(0) { $0 + $1.totalTokens },
                    projectCachedInputTokens: summary.sessions.reduce(0) { $0 + $1.cachedInputTokens },
                    todayTotalTokens: todayTotal,
                    todayCachedInputTokens: summary.todayTimeBuckets.reduce(0) { $0 + $1.cachedInputTokens },
                    currentTool: nil,
                    currentModel: nil,
                    currentContextUsagePercent: nil,
                    currentContextUsedTokens: nil,
                    currentContextWindow: nil,
                    currentSessionUpdatedAt: summary.sessions.first?.lastSeenAt
                ),
                sessions: summary.sessions,
                heatmap: summary.heatmap,
                todayTimeBuckets: summary.todayTimeBuckets,
                toolBreakdown: summary.toolBreakdown,
                modelBreakdown: summary.modelBreakdown,
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            )
        }
    }

    func saveProjectIndexState(for snapshot: AIIndexedProjectSnapshot, projectPath: String) {
        try? withDatabase { db in
            try execute(db, sql: """
                INSERT INTO ai_history_project_index_state (project_id, project_name, project_path, indexed_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(project_id) DO UPDATE SET
                    project_name=excluded.project_name,
                    project_path=excluded.project_path,
                    indexed_at=excluded.indexed_at;
            """, bindings: [
                snapshot.projectID.uuidString,
                snapshot.projectName,
                projectPath,
                snapshot.indexedAt.timeIntervalSince1970,
            ])
        }
    }

    func deleteProjectIndexState(projectID: UUID) {
        try? withDatabase { db in
            try execute(db, sql: "DELETE FROM ai_history_project_index_state WHERE project_id = ?;", bindings: [projectID.uuidString])
        }
    }

    func externalFileCheckpoint(
        source: String,
        filePath: String,
        projectPath: String
    ) -> AIExternalFileCheckpoint? {
        try? withDatabase { db in
            let sql = """
            SELECT file_modified_at, file_size, last_offset, last_indexed_at, payload_json
            FROM ai_history_file_checkpoint
            WHERE source = ? AND file_path = ? AND project_path = ?
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, projectPath, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            let fileModifiedAt = sqlite3_column_double(statement, 0)
            let fileSize = UInt64(max(0, sqlite3_column_int64(statement, 1)))
            let lastOffset = UInt64(max(0, sqlite3_column_int64(statement, 2)))
            let lastIndexedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let payloadJSON = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let payload = decodeCheckpointPayload(payloadJSON)
            return AIExternalFileCheckpoint(
                source: source,
                filePath: filePath,
                projectPath: projectPath,
                fileModifiedAt: fileModifiedAt,
                fileSize: fileSize,
                lastOffset: lastOffset,
                lastIndexedAt: lastIndexedAt,
                payload: payload
            )
        }
    }

    func storedExternalSummary(source: String, filePath: String, projectPath: String, modifiedAt: Double) -> AIExternalFileSummary? {
        try? withDatabase { db in
            guard hasNormalizedExternalSummary(
                db: db,
                source: source,
                filePath: filePath,
                projectPath: projectPath,
                modifiedAt: modifiedAt
            ) else {
                return nil
            }
            return loadNormalizedExternalSummary(
                db: db,
                source: source,
                filePath: filePath,
                projectPath: projectPath,
                modifiedAt: modifiedAt
            )
        }
    }

    func storedExternalSummary(
        source: String,
        filePath: String,
        projectPath: String
    ) -> AIExternalFileSummary? {
        try? withDatabase { db in
            let sql = """
            SELECT file_modified_at
            FROM ai_history_file_state
            WHERE source = ? AND file_path = ? AND project_path = ?
            LIMIT 1;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, projectPath, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            return loadNormalizedExternalSummary(
                db: db,
                source: source,
                filePath: filePath,
                projectPath: projectPath,
                modifiedAt: sqlite3_column_double(statement, 0)
            )
        }
    }

    func saveExternalSummary(_ summary: AIExternalFileSummary) {
        try? withDatabase { db in
            try replaceNormalizedExternalSummary(db: db, summary: summary, checkpoint: nil)
        }
    }

    func saveExternalSummary(
        _ summary: AIExternalFileSummary,
        checkpoint: AIExternalFileCheckpoint?
    ) {
        try? withDatabase { db in
            try replaceNormalizedExternalSummary(db: db, summary: summary, checkpoint: checkpoint)
        }
    }

    func storedExternalSummaries(source: String, projectPath: String) -> [AIExternalFileSummary] {
        (try? withDatabase { db in
            let sql = """
            SELECT file_path, file_modified_at
            FROM ai_history_file_state
            WHERE source = ? AND project_path = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, projectPath, -1, SQLITE_TRANSIENT)

            var items: [AIExternalFileSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawPath = sqlite3_column_text(statement, 0) else { continue }
                let filePath = String(cString: rawPath)
                let modifiedAt = sqlite3_column_double(statement, 1)
                if let item = loadNormalizedExternalSummary(
                    db: db,
                    source: source,
                    filePath: filePath,
                    projectPath: projectPath,
                    modifiedAt: modifiedAt
                ) {
                    items.append(item)
                }
            }
            return items
        }) ?? []
    }

    func deleteExternalSummaries(projectPath: String) {
        try? withDatabase { db in
            try execute(db, sql: "DELETE FROM ai_history_file_checkpoint WHERE project_path = ?;", bindings: [projectPath])
            try execute(db, sql: "DELETE FROM ai_history_file_state WHERE project_path = ?;", bindings: [projectPath])
            try execute(db, sql: "DELETE FROM ai_history_file_session_link WHERE project_path = ?;", bindings: [projectPath])
            try execute(db, sql: "DELETE FROM ai_history_file_usage_bucket WHERE project_path = ?;", bindings: [projectPath])
        }
    }
}
