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

    func testCompletionPresentationExpiresForPet() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = AppModel.ProjectCompletionPresentation(
            tool: "codex",
            finishedAt: now,
            exitCode: 0,
            presentedAt: now.addingTimeInterval(-ProjectActivityPhase.petCompletedActivityStatusDisplayDuration + 0.1)
        )
        let expired = AppModel.ProjectCompletionPresentation(
            tool: "codex",
            finishedAt: now,
            exitCode: 1,
            presentedAt: now.addingTimeInterval(-ProjectActivityPhase.petCompletedActivityStatusDisplayDuration - 0.1)
        )

        XCTAssertTrue(fresh.isFreshForPet(now: now))
        XCTAssertFalse(expired.isFreshForPet(now: now))
    }
}
