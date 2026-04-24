import XCTest
@testable import DmuxWorkspace

final class MemoryCoordinatorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmux-memory-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        databaseURL = temporaryDirectoryURL.appendingPathComponent("memory.sqlite3", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        databaseURL = nil
    }

    func testCurrentStatusSnapshotReflectsUnderlyingQueueState() async throws {
        let store = MemoryStore(databaseURL: databaseURL)
        let coordinator = MemoryCoordinator(store: store)
        let projectID = UUID()

        let initial = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(initial.status, .idle)
        XCTAssertEqual(initial.pendingCount, 0)
        XCTAssertEqual(initial.runningCount, 0)
        XCTAssertNil(initial.lastError)

        XCTAssertTrue(
            try store.enqueueExtractionIfNeeded(
                projectID: projectID,
                tool: "codex",
                sessionID: "session-1",
                transcriptPath: "/tmp/transcript.jsonl",
                sourceFingerprint: "fp-1"
            )
        )

        let queued = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(queued.status, .queued)
        XCTAssertEqual(queued.pendingCount, 1)
        XCTAssertEqual(queued.runningCount, 0)
        XCTAssertNil(queued.lastError)

        let task = try XCTUnwrap(store.nextPendingExtractionTask())
        try store.markExtractionTaskRunning(task.id)

        let processing = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(processing.status, .processing)
        XCTAssertEqual(processing.pendingCount, 0)
        XCTAssertEqual(processing.runningCount, 1)
        XCTAssertNil(processing.lastError)

        try store.markExtractionTaskFailed(task.id, error: "provider unavailable")

        let failed = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.pendingCount, 0)
        XCTAssertEqual(failed.runningCount, 0)
        XCTAssertEqual(failed.lastError, "provider unavailable")
    }

    func testRecoverInterruptedExtractionsRequeuesRunningTasks() async throws {
        let store = MemoryStore(databaseURL: databaseURL)
        let coordinator = MemoryCoordinator(store: store)

        XCTAssertTrue(
            try store.enqueueExtractionIfNeeded(
                projectID: UUID(),
                tool: "codex",
                sessionID: "session-2",
                transcriptPath: "/tmp/transcript-2.jsonl",
                sourceFingerprint: "fp-2"
            )
        )

        let task = try XCTUnwrap(store.nextPendingExtractionTask())
        try store.markExtractionTaskRunning(task.id)

        let running = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(running.status, .processing)
        XCTAssertEqual(running.runningCount, 1)

        await coordinator.recoverInterruptedExtractions()

        let recovered = await coordinator.currentStatusSnapshot()
        XCTAssertEqual(recovered.status, .queued)
        XCTAssertEqual(recovered.pendingCount, 1)
        XCTAssertEqual(recovered.runningCount, 0)
        XCTAssertNil(recovered.lastError)
    }
}
