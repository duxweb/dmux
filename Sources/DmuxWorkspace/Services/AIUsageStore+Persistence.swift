import Foundation
import SQLite3

extension AIUsageStore {
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
