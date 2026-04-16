import Foundation
import SQLite3

actor OpenCodeRuntimeProbeService {
    private var sessionIDByRuntimeSessionID: [String: String] = [:]

    func snapshot(
        runtimeSessionID: String,
        projectPath: String,
        startedAt: Double
    ) -> AIRuntimeContextSnapshot? {
        let dbURL = AIRuntimeSourceLocator.opencodeDatabaseURL()
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let latestSessionID: String
        if let existingSessionID = sessionIDByRuntimeSessionID[runtimeSessionID] {
            latestSessionID = existingSessionID
        } else {
            let latestSessionSQL = """
            SELECT s.id
            FROM session s
            JOIN message m ON m.session_id = s.id
            WHERE s.directory = ?
              AND m.time_created >= ?
            ORDER BY m.time_created DESC
            LIMIT 1;
            """

            var latestSessionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, latestSessionSQL, -1, &latestSessionStatement, nil) == SQLITE_OK,
                  let latestSessionStatement else {
                return nil
            }
            defer { sqlite3_finalize(latestSessionStatement) }
            sqlite3_bind_text(latestSessionStatement, 1, projectPath, -1, SQLITE_TRANSIENT_OPENCODE_RUNTIME)
            sqlite3_bind_double(latestSessionStatement, 2, (startedAt - 2) * 1000)

            guard sqlite3_step(latestSessionStatement) == SQLITE_ROW,
                  let latestSessionIDPointer = sqlite3_column_text(latestSessionStatement, 0) else {
                return nil
            }
            latestSessionID = String(cString: latestSessionIDPointer)
            sessionIDByRuntimeSessionID[runtimeSessionID] = latestSessionID
        }

        let sql = """
        SELECT json_extract(m.data, '$.modelID') AS model,
               COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS input_tokens,
               COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS output_tokens,
               COALESCE(json_extract(m.data, '$.tokens.cache.read'), 0) AS cache_read_tokens,
               COALESCE(json_extract(m.data, '$.tokens.cache.write'), 0) AS cache_write_tokens,
               COALESCE(json_extract(m.data, '$.tokens.total'), 0) AS total_tokens,
               COALESCE(json_extract(m.data, '$.time.completed'), json_extract(m.data, '$.time.created'), 0) AS completed_at
        FROM session s
        JOIN message m ON m.session_id = s.id
        WHERE s.directory = ?
          AND s.id = ?
        ORDER BY m.time_created DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, projectPath, -1, SQLITE_TRANSIENT_OPENCODE_RUNTIME)
        sqlite3_bind_text(statement, 2, latestSessionID, -1, SQLITE_TRANSIENT_OPENCODE_RUNTIME)

        var latestModel: String?
        var inputTokens = 0
        var outputTokens = 0
        var totalTokens = 0
        var updatedAt = 0.0

        while sqlite3_step(statement) == SQLITE_ROW {
            if latestModel == nil, let rawModel = sqlite3_column_text(statement, 0) {
                let model = String(cString: rawModel)
                if !model.isEmpty {
                    latestModel = model
                }
            }
            let input = Int(sqlite3_column_int64(statement, 1))
            let output = Int(sqlite3_column_int64(statement, 2))
            let cacheRead = Int(sqlite3_column_int64(statement, 3))
            let cacheWrite = Int(sqlite3_column_int64(statement, 4))
            let explicitTotal = Int(sqlite3_column_int64(statement, 5))
            inputTokens += input + cacheRead + cacheWrite
            outputTokens += output
            totalTokens += max(explicitTotal, input + output + cacheRead + cacheWrite)
            updatedAt = max(updatedAt, sqlite3_column_double(statement, 6) / 1000)
        }

        guard updatedAt > 0 else {
            return nil
        }

        return AIRuntimeContextSnapshot(
            tool: "opencode",
            externalSessionID: latestSessionID,
            model: latestModel,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            updatedAt: updatedAt,
            responseState: nil
        )
    }
}

private let SQLITE_TRANSIENT_OPENCODE_RUNTIME = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
