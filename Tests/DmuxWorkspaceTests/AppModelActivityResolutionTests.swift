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

    @MainActor
    func testProjectCompletionPresentationRemainsUntilDismissed() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let now = Date(timeIntervalSince1970: 1_000)
        let finishedAt = now.addingTimeInterval(-3_600)
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let project = Project(
            id: projectID,
            name: "Root",
            path: "/tmp/project-\(projectID.uuidString)",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [project]
        model.activityCacheByProjectID[project.id] = AppModel.ProjectActivityCache(
            completionPresentation: AppModel.ProjectCompletionPresentation(
                tool: "codex",
                finishedAt: finishedAt,
                exitCode: 0,
                presentedAt: finishedAt
            )
        )

        XCTAssertEqual(
            model.resolvedProjectActivityPhase(projectID: project.id),
            .completed(tool: "codex", finishedAt: finishedAt, exitCode: 0)
        )
        XCTAssertTrue(model.dismissCompletionPresentationIfNeeded(projectID: project.id, reason: "test"))
        XCTAssertEqual(model.resolvedProjectActivityPhase(projectID: project.id), .idle)
    }

    func testCompletedActivityPhaseExpiresForPetOnly() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = ProjectActivityPhase.completed(
            tool: "codex",
            finishedAt: now.addingTimeInterval(-ProjectActivityPhase.petCompletedActivityStatusDisplayDuration + 0.1),
            exitCode: 0
        )
        let expired = ProjectActivityPhase.completed(
            tool: "codex",
            finishedAt: now.addingTimeInterval(-ProjectActivityPhase.petCompletedActivityStatusDisplayDuration - 0.1),
            exitCode: 1
        )

        XCTAssertTrue(fresh.isPetActivityStatusFreshForPet(now: now))
        XCTAssertFalse(expired.isPetActivityStatusFreshForPet(now: now))
    }
}
