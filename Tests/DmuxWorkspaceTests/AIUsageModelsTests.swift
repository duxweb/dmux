import XCTest
@testable import DmuxWorkspace

final class AIUsageModelsTests: XCTestCase {
    func testDisplayedCurrentTotalTokensUsesSessionTotals() {
        let snapshot = AITerminalSessionSnapshot(
            sessionID: UUID(),
            externalSessionID: "codex-session",
            projectID: UUID(),
            projectName: "Project",
            sessionTitle: "Session",
            tool: "codex",
            model: "gpt-5.4",
            status: "running",
            isRunning: true,
            startedAt: nil,
            updatedAt: Date(),
            currentInputTokens: 700,
            currentOutputTokens: 300,
            currentTotalTokens: 1_000,
            currentCachedInputTokens: 150,
            baselineInputTokens: 0,
            baselineOutputTokens: 0,
            baselineTotalTokens: 900,
            baselineCachedInputTokens: 120,
            currentContextWindow: nil,
            currentContextUsedTokens: nil,
            currentContextUsagePercent: nil,
            wasInterrupted: false,
            hasCompletedTurn: false
        )

        XCTAssertEqual(snapshot.displayedCurrentTotalTokens(mode: .normalized), 1_000)
        XCTAssertEqual(snapshot.displayedCurrentTotalTokens(mode: .includingCache), 1_150)
    }
}
