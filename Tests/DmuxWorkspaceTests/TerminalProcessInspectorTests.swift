import XCTest
@testable import DmuxWorkspace

final class TerminalProcessInspectorTests: XCTestCase {
    func testOrphanedManagedAIProcessGroupsExcludeActiveInstances() {
        let inspector = TerminalProcessInspector(
            snapshotProvider: {
                [
                    .init(
                        pid: 101,
                        ppid: 1,
                        pgid: 101,
                        command: "/bin/zsh /Applications/Codux.app/.../tool-wrapper.sh codex DMUX_SESSION_INSTANCE_ID=active-1 DMUX_SESSION_ID=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA DMUX_PROJECT_PATH=/Volumes/Web/a DMUX_RUNTIME_SOCKET=/tmp/dmux-runtime-events.sock TERM_PROGRAM=dmux DMUX_ACTIVE_AI_TOOL=codex"
                    ),
                    .init(
                        pid: 102,
                        ppid: 101,
                        pgid: 101,
                        command: "/Users/test/.nvm/.../codex DMUX_SESSION_INSTANCE_ID=active-1 DMUX_RUNTIME_SOCKET=/tmp/dmux-runtime-events.sock TERM_PROGRAM=dmux"
                    ),
                    .init(
                        pid: 201,
                        ppid: 1,
                        pgid: 201,
                        command: "/bin/zsh /Applications/Codux.app/.../tool-wrapper.sh claude DMUX_SESSION_INSTANCE_ID=stale-1 DMUX_SESSION_ID=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB DMUX_PROJECT_PATH=/Volumes/Web/b DMUX_RUNTIME_SOCKET=/tmp/dmux-runtime-events.sock TERM_PROGRAM=dmux DMUX_ACTIVE_AI_TOOL=claude"
                    ),
                    .init(
                        pid: 202,
                        ppid: 201,
                        pgid: 201,
                        command: "/Users/test/.local/bin/claude DMUX_SESSION_INSTANCE_ID=stale-1 DMUX_RUNTIME_SOCKET=/tmp/dmux-runtime-events.sock TERM_PROGRAM=dmux"
                    ),
                ]
            }
        )

        let groups = inspector.orphanedManagedAIProcessGroups(
            activeSessionInstanceIDs: ["active-1"]
        )

        XCTAssertEqual(
            groups,
            [
                .init(
                    pgid: 201,
                    tool: "claude",
                    sessionInstanceID: "stale-1",
                    sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
                    projectPath: "/Volumes/Web/b"
                )
            ]
        )
    }

    func testManagedSessionObservationOnlyReturnsDmuxManagedProcesses() {
        let inspector = TerminalProcessInspector(
            snapshotProvider: {
                [
                    .init(
                        pid: 101,
                        ppid: 1,
                        pgid: 101,
                        command: "/Users/test/.nvm/.../codex DMUX_SESSION_INSTANCE_ID=instance-a DMUX_RUNTIME_SOCKET=/tmp/dmux-runtime-events.sock TERM_PROGRAM=dmux"
                    ),
                    .init(
                        pid: 102,
                        ppid: 1,
                        pgid: 102,
                        command: "/Users/test/.vscode/.../codex app-server --analytics-default-enabled"
                    ),
                ]
            }
        )

        XCTAssertEqual(inspector.managedSessionObservation().liveInstanceIDs, ["instance-a"])
    }

    func testManagedSessionObservationTreatsWrapperWithoutEnvAsCandidate() {
        let inspector = TerminalProcessInspector(
            snapshotProvider: {
                [
                    .init(
                        pid: 101,
                        ppid: 1,
                        pgid: 101,
                        command: "/bin/zsh /Applications/Codux.app/Contents/Resources/runtime-root/scripts/wrappers/bin/../tool-wrapper.sh codex"
                    ),
                    .init(
                        pid: 102,
                        ppid: 101,
                        pgid: 101,
                        command: "/Users/test/.local/bin/claude --session-id abc"
                    )
                ]
            }
        )

        let observation = inspector.managedSessionObservation()
        XCTAssertTrue(observation.hasManagedProcessCandidates)
        XCTAssertTrue(observation.liveInstanceIDs.isEmpty)
    }
}
