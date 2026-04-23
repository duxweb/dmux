import XCTest
@testable import DmuxWorkspace

@MainActor
final class AIStatsStoreLiveTests: XCTestCase {
    private let sessionStore = AISessionStore.shared

    override func setUp() async throws {
        sessionStore.reset()
    }

    override func tearDown() async throws {
        sessionStore.reset()
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
}
