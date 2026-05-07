import XCTest
@testable import DmuxWorkspace

@MainActor
final class PetSpeechCatalogTests: XCTestCase {
    func testConcreteModesHaveEightTemplatesForEveryEvent() {
        let catalog = PetSpeechCatalog()
        for mode in PetSpeechMode.concreteModes {
            for kind in PetSpeechEventKind.allCases {
                XCTAssertGreaterThanOrEqual(
                    catalog.templateCount(mode: mode, eventKind: kind),
                    8,
                    "\(mode.rawValue) \(kind.rawValue)"
                )
            }
        }
    }

    func testMissingPayloadNeverReturnsEmptyOrRawPlaceholder() {
        let catalog = PetSpeechCatalog()
        for mode in PetSpeechMode.concreteModes {
            for kind in PetSpeechEventKind.allCases {
                let line = catalog.pickLine(
                    mode: mode,
                    event: PetSpeechEvent(kind: kind)
                )
                XCTAssertFalse(line.text.isEmpty, "\(mode.rawValue) \(kind.rawValue)")
                XCTAssertFalse(line.text.contains("{"), line.text)
                XCTAssertFalse(line.text.contains("}"), line.text)
                XCTAssertLessThanOrEqual(line.text.count, 36, line.text)
            }
        }
    }

    func testTemplatePickerKeepsBasicVariety() {
        let catalog = PetSpeechCatalog()
        var lines = Set<String>()
        for _ in 0 ..< 100 {
            lines.insert(
                catalog.pickLine(
                    mode: .encourage,
                    event: PetSpeechEvent(
                        kind: .turnCompletedLong,
                        payload: ["durationMin": "42", "tool": "codex", "tokensK": "12K"]
                    )
                ).text
            )
        }
        XCTAssertGreaterThanOrEqual(lines.count, 6)
    }
}

@MainActor
final class PetSpeechCoordinatorTests: XCTestCase {
    func testModeOffClearsAndSuppressesSpeech() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )
        coordinator.notify(PetSpeechEvent(kind: .petLevelUp, payload: ["level": "2"]))
        XCTAssertNotNil(coordinator.currentLine)

        settings.speechMode = .off
        coordinator.notify(PetSpeechEvent(kind: .petLevelUp, payload: ["level": "3"]))
        XCTAssertNil(coordinator.currentLine)
    }

    func testActivityStatusDisplaysWhenSpeechModeIsOff() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.running(tool: "codex"))

        XCTAssertNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentActivityLine?.key, "running:codex")
        XCTAssertEqual(coordinator.displayLine?.tone, .normal)
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.text, "codex is running")
    }

    func testRunningActivityStatusDisplaysAssistantPreviewWhenAvailable() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(
            .running(tool: "codex"),
            assistantPreview: "我先检查项目结构。\n然后确认入口和配置。"
        )

        XCTAssertNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentActivityLine?.key, "running-preview:codex:我先检查项目结构。\n然后确认入口和配置。")
        XCTAssertEqual(coordinator.currentActivityLine?.isLivePreview, true)
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.text, "我先检查项目结构。\n然后确认入口和配置。")
    }

    func testWaitingInputActivityStatusUsesAttentionToneWhenSpeechModeIsOff() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.waitingInput(tool: "codex"))

        XCTAssertNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentActivityLine?.key, "waiting:codex")
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.tone, .attention)
        XCTAssertEqual(coordinator.displayLine?.text, "codex needs input")
    }

    func testPermissionActivityStatusUsesAttentionToneAndStaysVisible() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updatePermissionActivityStatus(
            tool: "codex",
            targetToolName: "Bash"
        )

        XCTAssertNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentActivityLine?.key, "permission:codex:Bash:")
        XCTAssertNotNil(coordinator.currentActivityLine?.expiresAt)
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.tone, .attention)
        XCTAssertEqual(coordinator.displayLine?.text, "codex needs permission for Bash")
    }

    func testPermissionActivityStatusIsNotOverwrittenByRunningStatus() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updatePermissionActivityStatus(
            tool: "codex",
            targetToolName: "Bash"
        )
        coordinator.updateActivityStatus(.running(tool: "codex"))

        XCTAssertEqual(coordinator.currentActivityLine?.key, "permission:codex:Bash:")
        XCTAssertEqual(coordinator.displayLine?.tone, .attention)
        XCTAssertEqual(coordinator.displayLine?.text, "codex needs permission for Bash")
    }

    func testPermissionActivityStatusRestoresDeferredRunningStatusAfterTTL() async {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updatePermissionActivityStatus(
            tool: "codex",
            targetToolName: "Bash",
            now: Date().addingTimeInterval(-20)
        )
        coordinator.updateActivityStatus(.running(tool: "codex"))

        XCTAssertEqual(coordinator.currentActivityLine?.key, "permission:codex:Bash:")
        XCTAssertEqual(coordinator.displayLine?.tone, .attention)

        try? await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(coordinator.currentActivityLine?.key, "running:codex")
        XCTAssertEqual(coordinator.displayLine?.tone, .normal)
        XCTAssertEqual(coordinator.displayLine?.text, "codex is running")
    }

    func testActivityStatusOverridesSpeechLine() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        settings.speechQuietDuringWork = false
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.running(tool: "codex"))
        let activityLine = coordinator.displayLine
        coordinator.notify(PetSpeechEvent(kind: .petLevelUp, payload: ["level": "2"]))

        XCTAssertEqual(activityLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.text, "codex is running")
        XCTAssertEqual(coordinator.currentActivityLine?.key, "running:codex")
        XCTAssertEqual(coordinator.currentLine?.eventKind, .petLevelUp)
    }

    func testIdleMonologueDoesNotOverrideActivityStatus() {
        let coordinator = PetSpeechCoordinator(idleMonologueDelayProvider: { 60 })
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        settings.speechQuietDuringWork = false
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.running(tool: "codex"))
        coordinator.notify(PetSpeechEvent(kind: .idleMonologue))

        XCTAssertEqual(coordinator.currentLine?.eventKind, .idleMonologue)
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.text, "codex is running")
    }

    func testAttentionActivityStatusOverridesSpeechLine() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        settings.speechQuietDuringWork = false
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.waitingInput(tool: "codex"))
        coordinator.notify(PetSpeechEvent(kind: .petLevelUp, payload: ["level": "2"]))

        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.tone, .attention)
        XCTAssertEqual(coordinator.displayLine?.text, "codex needs input")
        XCTAssertEqual(coordinator.currentLine?.eventKind, .petLevelUp)
    }

    func testCompletedActivityStatusUsesSuccessTone() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.completed(tool: "codex", finishedAt: Date(), exitCode: nil))

        XCTAssertEqual(coordinator.currentActivityLine?.key, "completed:codex")
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.tone, .success)
        XCTAssertEqual(coordinator.displayLine?.text, "codex completed")
    }

    func testFailedActivityStatusUsesWarningTone() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.updateActivityStatus(.completed(tool: "codex", finishedAt: Date(), exitCode: 1))

        XCTAssertEqual(coordinator.currentActivityLine?.key, "failed:codex:1")
        XCTAssertEqual(coordinator.displayLine?.isActivityStatus, true)
        XCTAssertEqual(coordinator.displayLine?.tone, .warning)
        XCTAssertEqual(coordinator.displayLine?.text, "codex failed")
    }

    func testModeOffStillAllowsReminderEvents() {
        let coordinator = PetSpeechCoordinator()
        let settings = AppAIPetSettings()
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.notify(PetSpeechEvent(kind: .reminderSedentary, payload: ["durationMin": "30"]))
        XCTAssertNotNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentLine?.eventKind, .reminderSedentary)
    }

    func testQuietFrequencySuppressesDailyButAllowsMilestone() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .quiet
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.notify(PetSpeechEvent(kind: .turnCompletedFast, payload: ["tool": "codex"]))
        XCTAssertNil(coordinator.currentLine)

        coordinator.notify(PetSpeechEvent(kind: .petLevelUp, payload: ["level": "2"]))
        XCTAssertNotNil(coordinator.currentLine)
    }

    func testReminderEventsBypassSpeechFrequencyTier() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .quiet
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.notify(PetSpeechEvent(kind: .reminderHydration, payload: ["durationMin": "120"]))
        XCTAssertNotNil(coordinator.currentLine)
        XCTAssertEqual(coordinator.currentLine?.eventKind, .reminderHydration)
    }

    func testReminderEventsUseWarningTone() {
        for kind in [PetSpeechEventKind.reminderHydration, .reminderSedentary, .reminderLateNight] {
            let coordinator = PetSpeechCoordinator()
            var settings = AppAIPetSettings()
            settings.speechMode = .encourage
            settings.speechFrequency = .quiet
            coordinator.configure(
                settings: { settings },
                petName: { "测试宠" },
                activitySnapshots: { [] }
            )

            coordinator.notify(PetSpeechEvent(kind: kind, payload: ["durationMin": "120"]))

            XCTAssertEqual(coordinator.currentLine?.eventKind, kind)
            XCTAssertEqual(coordinator.displayLine?.isActivityStatus, false)
            XCTAssertEqual(coordinator.displayLine?.tone, .warning)
        }
    }

    func testTurnFamilyCooldownSuppressesRapidFollowUp() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        settings.speechQuietDuringWork = false
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        coordinator.notify(PetSpeechEvent(kind: .turnStarted, payload: ["tool": "codex"]))
        let firstLine = coordinator.currentLine
        XCTAssertNotNil(firstLine)
        XCTAssertEqual(firstLine?.eventKind, .turnStarted)

        coordinator.notify(PetSpeechEvent(kind: .turnCompletedFast, payload: ["tool": "codex", "durationSec": "12"]))
        XCTAssertEqual(coordinator.currentLine?.id, firstLine?.id, "turn family cooldown should keep the previous line")
    }

    func testUsageDailyRecordDoesNotBypassCooldown() {
        let coordinator = PetSpeechCoordinator()
        var settings = AppAIPetSettings()
        settings.speechMode = .roast
        settings.speechFrequency = .chatterbox
        settings.speechQuietDuringWork = false
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { [] }
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        coordinator.notify(PetSpeechEvent(kind: .usageDailyRecord, payload: ["tokensK": "20000K"], occurredAt: now))
        let firstLine = coordinator.currentLine
        coordinator.notify(PetSpeechEvent(kind: .usageDailyRecord, payload: ["tokensK": "20001K"], occurredAt: now.addingTimeInterval(10)))

        XCTAssertFalse(PetSpeechEvent(kind: .usageDailyRecord).isHardOverride)
        XCTAssertEqual(coordinator.currentLine, firstLine)
    }

    func testIdleMonologueUsesLLMReplacementWhenEnabled() async {
        let coordinator = PetSpeechCoordinator()
        var aiSettings = AppAISettings()
        aiSettings.pet.speechMode = .encourage
        aiSettings.pet.speechFrequency = .lively
        aiSettings.pet.speechLLMEnabled = true
        aiSettings.pet.speechQuietDuringWork = false
        var requestedKinds: [PetSpeechEventKind] = []
        coordinator.configure(
            settings: { aiSettings.pet },
            aiSettings: { aiSettings },
            petName: { "测试宠" },
            activitySnapshots: { [] },
            llmLineProvider: { event, _, _ in
                requestedKinds.append(event.kind)
                return "LLM 台词"
            }
        )

        coordinator.notify(PetSpeechEvent(kind: .idleMonologue))
        XCTAssertEqual(coordinator.currentLine?.source, .template)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.currentLine?.text, "LLM 台词")
        XCTAssertEqual(coordinator.currentLine?.source, .llm)
        XCTAssertEqual(requestedKinds, [.idleMonologue])
    }

    func testLLMReplacementDoesNotRunForNonIdleEvents() async {
        let coordinator = PetSpeechCoordinator()
        var aiSettings = AppAISettings()
        aiSettings.pet.speechMode = .encourage
        aiSettings.pet.speechFrequency = .lively
        aiSettings.pet.speechLLMEnabled = true
        aiSettings.pet.speechQuietDuringWork = false
        var requestedKinds: [PetSpeechEventKind] = []
        coordinator.configure(
            settings: { aiSettings.pet },
            aiSettings: { aiSettings },
            petName: { "测试宠" },
            activitySnapshots: { [] },
            llmLineProvider: { event, _, _ in
                requestedKinds.append(event.kind)
                return "LLM 台词"
            }
        )

        coordinator.notify(PetSpeechEvent(kind: .tokensBurst, payload: ["tokensK": "60K"]))

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.currentLine?.source, .template)
        XCTAssertTrue(requestedKinds.isEmpty)
    }

    func testStopCancelsPendingLLMReplacement() async {
        let coordinator = PetSpeechCoordinator()
        var aiSettings = AppAISettings()
        aiSettings.pet.speechMode = .encourage
        aiSettings.pet.speechFrequency = .lively
        aiSettings.pet.speechLLMEnabled = true
        aiSettings.pet.speechQuietDuringWork = false

        let providerStarted = expectation(description: "provider started")
        let providerCancelled = expectation(description: "provider cancelled")
        coordinator.configure(
            settings: { aiSettings.pet },
            aiSettings: { aiSettings },
            petName: { "测试宠" },
            activitySnapshots: { [] },
            llmLineProvider: { _, _, _ in
                providerStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(10))
                    return "late line"
                } catch {
                    providerCancelled.fulfill()
                    return nil
                }
            }
        )

        coordinator.notify(PetSpeechEvent(kind: .idleMonologue))
        await fulfillment(of: [providerStarted], timeout: 1)

        coordinator.stop()
        await fulfillment(of: [providerCancelled], timeout: 1)
        XCTAssertNotEqual(coordinator.currentLine?.source, .llm)
    }

    func testIdleMonologueIsScheduledAfterIdleWindow() {
        let coordinator = PetSpeechCoordinator(idleMonologueDelayProvider: { 60 })
        var settings = AppAIPetSettings()
        settings.speechMode = .encourage
        settings.speechFrequency = .lively
        settings.speechQuietDuringWork = false
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshots: [PetSpeechActivitySnapshot] = []
        coordinator.configure(
            settings: { settings },
            petName: { "测试宠" },
            activitySnapshots: { snapshots }
        )

        coordinator.runPeriodicChecksForTesting(now: start)
        coordinator.runPeriodicChecksForTesting(now: start.addingTimeInterval(300))
        XCTAssertNil(coordinator.currentLine)

        coordinator.runPeriodicChecksForTesting(now: start.addingTimeInterval(359))
        XCTAssertEqual(coordinator.currentLine?.eventKind, nil)

        coordinator.runPeriodicChecksForTesting(now: start.addingTimeInterval(360))
        XCTAssertEqual(coordinator.currentLine?.eventKind, .idleMonologue)

        snapshots = [
            PetSpeechActivitySnapshot(
                tool: "codex",
                model: "gpt-test",
                projectName: "demo",
                state: "responding",
                updatedAt: start.addingTimeInterval(361),
                activeStartedAt: start.addingTimeInterval(361),
                totalTokens: 0
            )
        ]
        coordinator.clearCurrentLine()
        coordinator.runPeriodicChecksForTesting(now: start.addingTimeInterval(420))
        XCTAssertNil(coordinator.currentLine)
    }
}

final class PetSpeechLLMServiceTests: XCTestCase {
    func testAuditPromptUsesIdleMetadataOnly() {
        let prompt = PetSpeechLLMService.auditPrompt(
            event: PetSpeechEvent(
                kind: .idleMonologue,
                payload: [
                    "tool": "codex",
                    "model": "gpt-test",
                    "hourLabel": "17:00",
                    "project": "demo",
                    "message": "不要泄露这段正文",
                    "body": "secret transcript",
                    "content": "private answer",
                ]
            ),
            mode: .roast
        )

        let combined = "\(prompt.systemPrompt)\n\(prompt.userPrompt)"
        XCTAssertTrue(combined.contains("codex"))
        XCTAssertTrue(combined.contains("gpt-test"))
        XCTAssertTrue(combined.contains("17:00"))
        XCTAssertTrue(combined.contains("demo"))
        XCTAssertTrue(combined.contains("简体中文") || combined.contains("Simplified Chinese"))
        XCTAssertFalse(combined.contains("不要泄露这段正文"))
        XCTAssertFalse(combined.contains("secret transcript"))
        XCTAssertFalse(combined.contains("private answer"))
    }
}
