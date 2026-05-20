import XCTest
@testable import DmuxWorkspace

final class KiroToolDriverTests: XCTestCase {
    func testRuntimeSnapshotReturnsTokensForMatchingProject() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectPath = "/tmp/kiro-driver-project-\(UUID().uuidString)"
        let sessionID = "driver-session-\(UUID().uuidString)"
        let sessionDir = AIRuntimeSourceLocator.kiroSessionsDirectoryURL(homeURL: tempDir)
            .appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let sessionFile = sessionDir.appendingPathComponent("\(sessionID).json")
        try kiroSessionJSON(sessionID: sessionID, cwd: projectPath, model: "claude-opus-4-7", turns: [
            (inputTokens: 200, outputTokens: 100, timestamp: "2026-05-04T10:00:00Z"),
            (inputTokens: 300, outputTokens: 150, timestamp: "2026-05-04T10:05:00Z"),
        ]).write(to: sessionFile, atomically: true, encoding: .utf8)

        let driver = KiroToolDriver(homeURL: tempDir)
        let state = makeSessionState(projectPath: projectPath, aiSessionID: sessionID)
        let snapshot = await driver.runtimeSnapshot(for: state)

        let result = try XCTUnwrap(snapshot)
        XCTAssertEqual(result.externalSessionID, sessionID)
        XCTAssertEqual(result.model, "claude-opus-4-7")
        XCTAssertEqual(result.inputTokens, 500)
        XCTAssertEqual(result.outputTokens, 250)
        XCTAssertEqual(result.totalTokens, 750)
    }

    func testRuntimeSnapshotReturnsNilForMismatchedProject() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = "mismatch-session-\(UUID().uuidString)"
        let sessionDir = AIRuntimeSourceLocator.kiroSessionsDirectoryURL(homeURL: tempDir)
            .appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let sessionFile = sessionDir.appendingPathComponent("\(sessionID).json")
        try kiroSessionJSON(sessionID: sessionID, cwd: "/tmp/other-project", model: nil, turns: [
            (inputTokens: 100, outputTokens: 50, timestamp: "2026-05-04T10:00:00Z"),
        ]).write(to: sessionFile, atomically: true, encoding: .utf8)

        let driver = KiroToolDriver(homeURL: tempDir)
        let state = makeSessionState(projectPath: "/tmp/different-project", aiSessionID: nil)
        let snapshot = await driver.runtimeSnapshot(for: state)

        XCTAssertNil(snapshot)
    }

    func testRuntimeSnapshotPrefersPinnedSessionID() async throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectPath = "/tmp/kiro-pinned-\(UUID().uuidString)"
        let sessionA = "session-a-\(UUID().uuidString)"
        let sessionB = "session-b-\(UUID().uuidString)"
        let sessionDir = AIRuntimeSourceLocator.kiroSessionsDirectoryURL(homeURL: tempDir)
            .appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        try kiroSessionJSON(sessionID: sessionA, cwd: projectPath, model: "model-a", turns: [
            (inputTokens: 100, outputTokens: 50, timestamp: "2026-05-04T09:00:00Z"),
        ]).write(to: sessionDir.appendingPathComponent("\(sessionA).json"), atomically: true, encoding: .utf8)

        try kiroSessionJSON(sessionID: sessionB, cwd: projectPath, model: "model-b", turns: [
            (inputTokens: 999, outputTokens: 999, timestamp: "2026-05-04T11:00:00Z"),
        ]).write(to: sessionDir.appendingPathComponent("\(sessionB).json"), atomically: true, encoding: .utf8)

        let driver = KiroToolDriver(homeURL: tempDir)
        let state = makeSessionState(projectPath: projectPath, aiSessionID: sessionA)
        let snapshot = await driver.runtimeSnapshot(for: state)

        let result = try XCTUnwrap(snapshot)
        XCTAssertEqual(result.externalSessionID, sessionA)
        XCTAssertEqual(result.model, "model-a")
    }

    func testRemoveSessionDeletesMatchingFile() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionID = "remove-session-\(UUID().uuidString)"
        let sessionDir = AIRuntimeSourceLocator.kiroSessionsDirectoryURL(homeURL: tempDir)
            .appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let sessionFile = sessionDir.appendingPathComponent("\(sessionID).json")
        try kiroSessionJSON(sessionID: sessionID, cwd: "/tmp/proj", model: nil, turns: []).write(
            to: sessionFile, atomically: true, encoding: .utf8
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))

        let driver = KiroToolDriver(homeURL: tempDir)
        let summary = makeSessionSummary(externalSessionID: sessionID)
        try driver.removeSession(summary)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    func testRemoveSessionThrowsWhenSessionNotFound() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let driver = KiroToolDriver(homeURL: tempDir)
        let summary = makeSessionSummary(externalSessionID: "nonexistent-\(UUID().uuidString)")

        XCTAssertThrowsError(try driver.removeSession(summary))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-driver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSessionState(
        projectPath: String,
        aiSessionID: String?
    ) -> AISessionStore.TerminalSessionState {
        AISessionStore.TerminalSessionState(
            terminalID: UUID(),
            projectID: UUID(),
            projectName: "TestProject",
            projectPath: projectPath,
            sessionTitle: "Terminal",
            tool: "kiro",
            aiSessionID: aiSessionID,
            state: .idle,
            updatedAt: Date().timeIntervalSince1970,
            wasInterrupted: false,
            hasCompletedTurn: false,
            transcriptPath: nil
        )
    }

    private func makeSessionSummary(externalSessionID: String) -> AISessionSummary {
        AISessionSummary(
            sessionID: UUID(),
            externalSessionID: externalSessionID,
            source: "kiro",
            projectName: "TestProject",
            sessionTitle: "Test",
            model: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedInputTokens: 0,
            totalTokens: 0,
            requestCount: 0,
            lastTool: "kiro",
            lastModel: nil,
            firstActivityAt: nil,
            lastActivityAt: nil
        )
    }

    private func kiroSessionJSON(
        sessionID: String,
        cwd: String,
        model: String?,
        turns: [(inputTokens: Int, outputTokens: Int, timestamp: String)]
    ) -> String {
        let turnsJSON = turns.map { turn in
            """
            {
              "result": {"Ok": {"id": "msg", "role": "assistant", "content": [], "meta": {}}},
              "end_timestamp": "\(turn.timestamp)",
              "input_token_count": \(turn.inputTokens),
              "output_token_count": \(turn.outputTokens),
              "total_request_count": 1
            }
            """
        }.joined(separator: ",\n")

        let modelJSON = model.map { "\"model_name\": \"\($0)\", \"model_id\": \"\($0)\", \"context_window_tokens\": 200000" }
            ?? "\"model_name\": \"\", \"model_id\": \"\", \"context_window_tokens\": 0"

        return """
        {
          "session_id": "\(sessionID)",
          "cwd": "\(cwd)",
          "title": "Test Session",
          "session_state": {
            "version": "v1",
            "conversation_metadata": {
              "user_turn_metadatas": [\(turnsJSON)]
            },
            "rts_model_state": {
              "conversation_id": "\(sessionID)",
              "model_info": {\(modelJSON)}
            }
          }
        }
        """
    }
}
