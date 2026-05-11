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

    func testStrippedManagedHookGroupsStripsLegacyGeminiHookForDifferentOwner() {
        let service = AIRuntimeBridgeService()
        let helperURL = URL(fileURLWithPath: "/tmp/new-runtime-hooks/dmux-ai-state.sh")
        let existingValue: [[String: Any]] = [[
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'session-start' 'codux' 'gemini'",
                    "statusMessage": "dmux gemini live",
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
            action: "session-start",
            tool: "gemini",
            owner: "codux-dev",
            helperScriptURL: helperURL,
            statusMessage: "dmux gemini live",
            stripAnyManagedHookForAction: true
        )

        let hooks = stripped.first?["hooks"] as? [[String: Any]]
        let commands = hooks?.compactMap { $0["command"] as? String } ?? []

        XCTAssertEqual(commands, ["echo user-hook"])
    }

    func testStrippedManagedHookGroupsDoesNotStripLegacyHookForOtherTool() {
        let service = AIRuntimeBridgeService()
        let helperURL = URL(fileURLWithPath: "/tmp/new-runtime-hooks/dmux-ai-state.sh")
        let existingValue: [[String: Any]] = [[
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'session-start' 'codux' 'claude'",
                    "statusMessage": "dmux gemini live",
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
            action: "session-start",
            tool: "gemini",
            owner: "codux-dev",
            helperScriptURL: helperURL,
            statusMessage: "dmux gemini live",
            stripAnyManagedHookForAction: true
        )

        let hooks = stripped.first?["hooks"] as? [[String: Any]]
        let commands = hooks?.compactMap { $0["command"] as? String } ?? []

        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertTrue(commands.contains(where: { $0.contains("'claude'") }))
    }

    func testUpdatedCodexConfigTextAddsNoticeSectionForEmptyConfig() {
        let service = AIRuntimeBridgeService()

        let updated = service.updatedCodexConfigText(from: "")

        XCTAssertEqual(
            updated,
            """
            suppress_unstable_features_warning = true

            [features]
            hooks = true

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

    func testUpdatedCodexConfigTextPreservesLegacyCodexHooksFeatureFlag() {
        let service = AIRuntimeBridgeService()
        let existing = """
        model = "gpt-5.5"

        [features]
        multi_agent = true
        codex_hooks = true
        memories = true
        """

        let updated = service.updatedCodexConfigText(from: existing)

        XCTAssertTrue(
            updated.contains(
                """
                [features]
                multi_agent = true
                codex_hooks = true
                memories = true
                """
            )
        )
        XCTAssertFalse(updated.split(separator: "\n").contains("hooks = true"))
    }

    func testUpdatedCodexConfigTextEnablesExistingHooksFeatureFlag() {
        let service = AIRuntimeBridgeService()
        let existing = """
        [features]
        hooks = false
        codex_hooks = true
        goals = true
        """

        let updated = service.updatedCodexConfigText(from: existing)

        XCTAssertTrue(
            updated.contains(
                """
                [features]
                hooks = true
                goals = true
                """
            )
        )
        XCTAssertFalse(updated.contains("codex_hooks"))
    }

    func testCodexCommandHookTrustHashMatchesCodexCanonicalHash() {
        let service = AIRuntimeBridgeService()
        let helperPath = "/Users/lixinhua/Library/Application Support/Codux-dev/runtime-support/runtime-hooks/dmux-ai-state.sh"
        let permissionCommand = "'\(helperPath)' 'codex-permission-request' 'codux-dev' 'codex'"

        let permissionHash = service.codexCommandHookTrustHash(
            eventLabel: "permission_request",
            matcher: "",
            command: permissionCommand,
            timeout: 1000,
            statusMessage: "dmux codex live"
        )

        XCTAssertEqual(
            permissionHash,
            "sha256:5751fbd5c0791a1f73c1e753ef07003ef86c311f7fc665d484578d6ad088a553"
        )

        let stopHash = service.codexCommandHookTrustHash(
            eventLabel: "stop",
            matcher: nil,
            command: "'\(helperPath)' 'codex-stop' 'codux-dev' 'codex'",
            timeout: 1000,
            statusMessage: "dmux codex live"
        )
        XCTAssertEqual(
            stopHash,
            "sha256:fa7a60c7aeccf818931c78e2495ddcb603af0ef12968a49eea1833d175eff9ef"
        )

        let promptHash = service.codexCommandHookTrustHash(
            eventLabel: "user_prompt_submit",
            matcher: nil,
            command: "'\(helperPath)' 'codex-prompt-submit' 'codux-dev' 'codex'",
            timeout: 1000,
            statusMessage: "dmux codex live"
        )
        XCTAssertEqual(
            promptHash,
            "sha256:c769c7426f00b21431139a62f27940030523341468a4c9b08564ddacecd4730d"
        )
    }

    func testUpdatedCodexConfigTextWritesManagedHookTrustStates() {
        let service = AIRuntimeBridgeService()
        let updated = service.updatedCodexConfigText(
            from: """
            [features]
            hooks = true

            [hooks.state."/Users/me/.codex/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:old"
            """,
            codexHookTrustStates: [
                AIRuntimeBridgeService.CodexHookTrustState(
                    key: "/Users/me/.codex/hooks.json:session_start:0:0",
                    trustedHash: "sha256:new"
                ),
            ]
        )

        XCTAssertTrue(
            updated.contains(
                """
                [hooks.state."/Users/me/.codex/hooks.json:session_start:0:0"]
                trusted_hash = "sha256:new"
                """
            )
        )
        XCTAssertFalse(updated.contains("sha256:old"))
    }

    func testManagedCodexHookTrustStatesOnlyIncludesRunnableCoduxHooks() {
        let service = AIRuntimeBridgeService()
        var root: [String: Any] = [:]
        service.installCodexHooks(&root)

        let states = service.managedCodexHookTrustStates(from: root)
        let labels = states.map(\.key).sorted()

        XCTAssertEqual(states.count, 4)
        XCTAssertTrue(labels.contains(where: { $0.contains(":permission_request:") }))
        XCTAssertTrue(labels.contains(where: { $0.contains(":session_start:") }))
        XCTAssertTrue(labels.contains(where: { $0.contains(":stop:") }))
        XCTAssertTrue(labels.contains(where: { $0.contains(":user_prompt_submit:") }))
        XCTAssertFalse(labels.contains(where: { $0.contains(":session_end:") }))
        XCTAssertTrue(states.allSatisfy { $0.trustedHash.hasPrefix("sha256:") })
    }

    func testInstallCodexHooksIncludesLifecyclePermissionEventsAndRemovesToolHooks() {
        let service = AIRuntimeBridgeService()
        var root: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'codex-pre-tool-use' 'codux' 'codex'",
                        "statusMessage": "dmux codex live",
                        "timeout": 1000,
                    ]],
                ]],
                "PostToolUse": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'codex-post-tool-use' 'codux' 'codex'",
                        "statusMessage": "dmux codex live",
                        "timeout": 1000,
                    ]],
                ]],
                "SessionEnd": [[
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'codex-session-end' 'codux' 'codex'",
                        "statusMessage": "dmux codex live",
                        "timeout": 1000,
                    ]],
                ]],
            ],
        ]

        service.installCodexHooks(&root)

        let hooksObject = root["hooks"] as? [String: Any] ?? [:]
        let expectedActions = [
            "SessionStart": "codex-session-start",
            "UserPromptSubmit": "codex-prompt-submit",
            "PermissionRequest": "codex-permission-request",
            "Stop": "codex-stop",
        ]

        for (eventKey, action) in expectedActions {
            let groups = hooksObject[eventKey] as? [[String: Any]]
            let commands = groups?
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String } ?? []
            XCTAssertTrue(
                commands.contains(where: { $0.contains("'\(action)'") }),
                "Expected \(eventKey) to install \(action), got \(commands)"
            )
        }

        XCTAssertNil(hooksObject["PreToolUse"])
        XCTAssertNil(hooksObject["PostToolUse"])
        XCTAssertNil(hooksObject["SessionEnd"])
    }

    func testInstallCodexHooksStripsLegacyManagedHooksForOtherOwners() {
        let service = AIRuntimeBridgeService()
        var root: [String: Any] = [
            "hooks": [
                "SessionStart": [[
                    "matcher": "",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "'/tmp/old-runtime-hooks/dmux-ai-state.sh' 'codex-session-start' 'codux' 'codex'",
                            "statusMessage": "dmux codex live",
                            "timeout": 1000,
                        ],
                        [
                            "type": "command",
                            "command": "echo user-hook",
                            "timeout": 1000,
                        ],
                    ],
                ]],
            ],
        ]

        service.installCodexHooks(&root)

        let hooksObject = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooksObject["SessionStart"] as? [[String: Any]]
        let commands = groups?
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String } ?? []

        XCTAssertTrue(commands.contains("echo user-hook"))
        XCTAssertEqual(commands.filter { $0.contains("'codex-session-start'") }.count, 1)
        XCTAssertFalse(commands.contains(where: { $0.contains("/tmp/old-runtime-hooks/dmux-ai-state.sh") }))
    }

    func testToolConfigFileURLIsIsolatedDuringTests() {
        let service = AIRuntimeBridgeService()
        let hooksURL = service.codexHooksFileURL()
        let realHomeCodexURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)

        XCTAssertFalse(hooksURL.path.hasPrefix(realHomeCodexURL.path + "/"))
        XCTAssertTrue(hooksURL.path.contains("external-tool-configs/.codex/hooks.json"))
    }
}
