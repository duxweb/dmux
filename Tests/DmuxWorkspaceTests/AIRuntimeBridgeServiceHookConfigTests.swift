import XCTest
@testable import DmuxWorkspace

final class AIRuntimeBridgeServiceHookConfigTests: XCTestCase {
    func testUpdatedCodexConfigTextAddsNoticeSectionForEmptyConfig() {
        let service = AIRuntimeBridgeService()

        let updated = service.updatedCodexConfigText(from: "")

        XCTAssertEqual(
            updated,
            """
            [notice]
            suppress_unstable_features_warning = true

            """
        )
    }

    func testUpdatedCodexConfigTextInsertsWarningInsideExistingNoticeSection() {
        let service = AIRuntimeBridgeService()
        let existing = """
        model = "gpt-5.4"

        [notice]
        hide_full_access_warning = true

        [notice.model_migrations]
        "gpt-5.1-codex-mini" = "gpt-5.4"
        """

        let updated = service.updatedCodexConfigText(from: existing)

        XCTAssertTrue(
            updated.contains(
                """
                [notice]
                suppress_unstable_features_warning = true
                hide_full_access_warning = true
                """
            )
        )
        XCTAssertEqual(
            updated.components(separatedBy: "suppress_unstable_features_warning = true").count - 1,
            1
        )
    }

    func testUpdatedCodexConfigTextCreatesParentNoticeSectionBeforeModelMigrations() {
        let service = AIRuntimeBridgeService()
        let existing = """
        model = "gpt-5.4"

        [notice.model_migrations]
        "gpt-5.1-codex-mini" = "gpt-5.4"
        suppress_unstable_features_warning = true
        """

        let updated = service.updatedCodexConfigText(from: existing)

        XCTAssertTrue(
            updated.contains(
                """
                [notice]
                suppress_unstable_features_warning = true

                [notice.model_migrations]
                """
            )
        )
        XCTAssertFalse(
            updated.contains(
                """
                [notice.model_migrations]
                "gpt-5.1-codex-mini" = "gpt-5.4"
                suppress_unstable_features_warning = true
                """
            )
        )
    }
}
