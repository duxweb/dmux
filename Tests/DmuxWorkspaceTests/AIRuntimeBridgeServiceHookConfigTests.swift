import XCTest
@testable import DmuxWorkspace

final class AIRuntimeBridgeServiceHookConfigTests: XCTestCase {
    func testHookCommandIncludesRuntimeOwner() {
        let service = AIRuntimeBridgeService()

        let command = service.hookCommand(
            helperScriptURL: URL(fileURLWithPath: "/tmp/dmux-ai-state.sh"),
            action: "prompt-submit",
            owner: "codux-dev",
            tool: "claude"
        )

        XCTAssertEqual(
            command,
            "'/tmp/dmux-ai-state.sh' 'prompt-submit' 'codux-dev' 'claude'"
        )
    }

    func testStrippedManagedHookGroupsPreservesOtherOwners() {
        let service = AIRuntimeBridgeService()
        let helperURL = URL(fileURLWithPath: "/tmp/dmux-ai-state.sh")
        let existingValue: [[String: Any]] = [[
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": service.hookCommand(
                        helperScriptURL: helperURL,
                        action: "prompt-submit",
                        owner: "codux",
                        tool: "claude"
                    ),
                    "statusMessage": "dmux claude live",
                    "timeout": 10,
                ],
                [
                    "type": "command",
                    "command": service.hookCommand(
                        helperScriptURL: helperURL,
                        action: "prompt-submit",
                        owner: "codux-dev",
                        tool: "claude"
                    ),
                    "statusMessage": "dmux claude live",
                    "timeout": 10,
                ],
                [
                    "type": "command",
                    "command": "echo user-hook",
                    "timeout": 10,
                ],
            ],
        ]]

        let stripped = service.strippedManagedHookGroups(
            existingValue: existingValue,
            action: "prompt-submit",
            owner: "codux-dev",
            helperScriptURL: helperURL,
            statusMessage: "dmux claude live"
        )

        let hooks = stripped.first?["hooks"] as? [[String: Any]]
        let commands = hooks?.compactMap { $0["command"] as? String } ?? []

        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertTrue(commands.contains(where: { $0.contains("'codux'") }))
        XCTAssertFalse(commands.contains(where: { $0.contains("'codux-dev'") }))
    }

    func testStrippedManagedHookGroupsRemovesLegacyOwnerlessHooksFromOldPaths() {
        let service = AIRuntimeBridgeService()
        let helperURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/Codux-dev/runtime-support/runtime-hooks/dmux-ai-state.sh")
        let existingValue: [[String: Any]] = [[
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": "'/Users/test/Library/Application Support/dmux-dev/runtime-hooks/dmux-ai-state.sh' 'prompt-submit' 'claude'",
                    "timeout": 10,
                ],
                [
                    "type": "command",
                    "command": service.hookCommand(
                        helperScriptURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/Codux/runtime-support/runtime-hooks/dmux-ai-state.sh"),
                        action: "prompt-submit",
                        owner: "codux",
                        tool: "claude"
                    ),
                    "timeout": 10,
                ],
                [
                    "type": "command",
                    "command": "echo user-hook",
                    "timeout": 10,
                ],
            ],
        ]]

        let stripped = service.strippedManagedHookGroups(
            existingValue: existingValue,
            action: "prompt-submit",
            owner: "codux-dev",
            helperScriptURL: helperURL,
            statusMessage: "dmux claude live"
        )

        let commands = (stripped.first?["hooks"] as? [[String: Any]])?
            .compactMap { $0["command"] as? String } ?? []

        XCTAssertEqual(commands.count, 2)
        XCTAssertFalse(commands.contains(where: { $0.contains("Application Support/dmux-dev") }))
        XCTAssertTrue(commands.contains(where: { $0.contains("'codux'") }))
        XCTAssertTrue(commands.contains("echo user-hook"))
    }

    func testUpdatedCodexConfigTextAddsNoticeSectionForEmptyConfig() {
        let service = AIRuntimeBridgeService()

        let updated = service.updatedCodexConfigText(from: "")

        XCTAssertEqual(
            updated,
            """
            suppress_unstable_features_warning = true

            """
        )
    }

    func testUpdatedCodexConfigTextInsertsWarningAtTopLevelBeforeNoticeSection() {
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
                suppress_unstable_features_warning = true

                [notice]
                hide_full_access_warning = true
                """
            )
        )
        XCTAssertEqual(
            updated.components(separatedBy: "suppress_unstable_features_warning = true").count - 1,
            1
        )
    }

    func testUpdatedCodexConfigTextMovesWarningOutOfNestedNoticeTable() {
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
