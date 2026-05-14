import XCTest
@testable import DmuxWorkspace

@MainActor
final class AIStatsStoreLiveTests: XCTestCase {
    private let sessionStore = AISessionStore.shared
    private var temporaryDirectoryURL: URL!
    private var databaseURL: URL!

    override func setUp() async throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dmux-ai-stats-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        databaseURL = temporaryDirectoryURL.appendingPathComponent("ai-usage.sqlite3", isDirectory: false)
        sessionStore.reset()
    }

    override func tearDown() async throws {
        sessionStore.reset()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        databaseURL = nil
    }

    func testResolveProjectLiveSnapshotsRetainsCompletedSession() {
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
        let terminalID = UUID()
        let now = Date().timeIntervalSince1970

        _ = sessionStore.apply(
            AIHookEvent(
                kind: .turnCompleted,
                terminalID: terminalID,
                terminalInstanceID: "instance-1",
                projectID: project.id,
                projectName: project.name,
                sessionTitle: "Terminal",
                tool: "codex",
                aiSessionID: "codex-session",
                model: "gpt-5.4",
                totalTokens: 42,
                updatedAt: now,
                metadata: .init(wasInterrupted: false, hasCompletedTurn: true)
            )
        )

        let statsStore = AIStatsStore()
        let snapshots = statsStore.resolveProjectLiveSnapshots(
            project: project,
            selectedSessionID: terminalID
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.sessionID, terminalID)
        XCTAssertEqual(snapshots.first?.currentTotalTokens, 0)
        XCTAssertEqual(snapshots.first?.status, "idle")
        XCTAssertEqual(snapshots.first?.hasCompletedTurn, true)
    }

    func testRefreshIfNeededDoesNotStartHistoryRefreshWhenPanelHidden() {
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
        let statsStore = AIStatsStore(aiUsageStore: AIUsageStore(databaseURL: databaseURL))
        statsStore.startTimers(
            isPanelVisible: { false },
            selectedProject: { project },
            selectedSessionID: { nil },
            projects: { [project] }
        )
        defer {
            statsStore.refreshTimer?.invalidate()
            statsStore.backgroundRefreshTimer?.invalidate()
            if let runtimeBridgeObserver = statsStore.runtimeBridgeObserver {
                NotificationCenter.default.removeObserver(runtimeBridgeObserver)
            }
            if let terminalFocusObserver = statsStore.terminalFocusObserver {
                NotificationCenter.default.removeObserver(terminalFocusObserver)
            }
        }

        statsStore.refreshIfNeeded(project: project, projects: [project], selectedSessionID: nil)

        XCTAssertNil(statsStore.refreshTasks[project.id])
        XCTAssertFalse(statsStore.openedProjectIDsThisLaunch.contains(project.id))
        XCTAssertEqual(statsStore.refreshState, .idle)
    }
}
