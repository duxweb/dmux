import XCTest
@testable import DmuxWorkspace

final class AppModelActivityResolutionTests: XCTestCase {
    func testResolveDisplayedActivityPhasePrefersRuntime() {
        let finishedAt = Date(timeIntervalSince1970: 100)

        let resolved = AppModel.resolveDisplayedActivityPhase(
            runtimePhase: .running(tool: "codex"),
            completionPhase: .completed(tool: "claude", finishedAt: finishedAt, exitCode: 0)
        )

        XCTAssertEqual(resolved, .running(tool: "codex"))
    }

    func testResolveDisplayedActivityPhaseFallsBackToCompletionPresentation() {
        let finishedAt = Date(timeIntervalSince1970: 100)

        let resolved = AppModel.resolveDisplayedActivityPhase(
            runtimePhase: .idle,
            completionPhase: .completed(tool: "codex", finishedAt: finishedAt, exitCode: 0)
        )

        XCTAssertEqual(resolved, .completed(tool: "codex", finishedAt: finishedAt, exitCode: 0))
    }
}
