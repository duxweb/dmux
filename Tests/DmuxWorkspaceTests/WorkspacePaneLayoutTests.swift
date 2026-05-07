import XCTest
@testable import DmuxWorkspace

@MainActor
final class WorkspacePaneLayoutTests: XCTestCase {
    func testTerminalStartupLoadingDoesNotBecomeProjectActivityLoading() {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let sessionID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [
            Project(
                id: projectID,
                name: "Project",
                path: "/tmp/project-\(projectID.uuidString)",
                shell: "/bin/zsh",
                defaultCommand: "",
                badgeText: nil,
                badgeSymbol: nil,
                badgeColorHex: nil,
                gitDefaultPushRemoteName: nil
            )
        ]
        model.workspaces = [makeWorkspace(projectID: projectID, sessionIDs: [sessionID])]

        model.noteTerminalLoadingState(sessionID, isLoading: true)

        XCTAssertEqual(model.resolvedProjectActivityPhase(projectID: projectID), ProjectActivityPhase.idle)
    }

    func testTopPaneDistributionDoesNotResetWhenSwitchingProjects() {
        let currentWorkspace = makeWorkspace(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sessionIDs: [
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            ]
        )
        let nextWorkspace = makeWorkspace(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sessionIDs: [
                UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            ]
        )

        XCTAssertFalse(
            TopPaneSplitController.shouldResetTopPaneDistribution(
                from: currentWorkspace,
                to: nextWorkspace
            )
        )
    }

    func testTopPaneDistributionResetsForSameProjectStructureChange() {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let currentWorkspace = makeWorkspace(
            projectID: projectID,
            sessionIDs: [
                UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            ]
        )
        let nextWorkspace = makeWorkspace(
            projectID: projectID,
            sessionIDs: [
                UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            ]
        )

        XCTAssertTrue(
            TopPaneSplitController.shouldResetTopPaneDistribution(
                from: currentWorkspace,
                to: nextWorkspace
            )
        )
    }

    func testBottomTabsCanBeRenamedAndReordered() {
        let first = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
        var workspace = makeWorkspace(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            sessionIDs: [first, second, third],
            topSessionIDs: [first],
            bottomTabSessionIDs: [second, third]
        )

        XCTAssertTrue(workspace.renameBottomTab(second, to: "  Logs  "))
        XCTAssertEqual(workspace.session(for: second)?.tabTitle, "Logs")
        XCTAssertFalse(workspace.renameBottomTab(first, to: "Top Pane"))

        XCTAssertTrue(workspace.moveBottomTab(second, to: third))
        XCTAssertEqual(workspace.bottomTabSessionIDs, [third, second])
        XCTAssertTrue(workspace.moveBottomTab(second, to: third))
        XCTAssertEqual(workspace.bottomTabSessionIDs, [second, third])
    }

    func testProjectsCanBeReorderedWithWorkspaces() {
        let first = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, name: "First")
        let second = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, name: "Second")
        let third = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!, name: "Third")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [first, second, third]
        model.workspaces = [
            makeWorkspace(projectID: first.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: second.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: third.id, sessionIDs: [UUID()]),
        ]

        model.moveProject(first.id, to: third.id)

        XCTAssertEqual(model.projects.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(model.workspaces.map(\.projectID), [second.id, third.id, first.id])

        model.moveProject(first.id, to: second.id)

        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(model.workspaces.map(\.projectID), [first.id, second.id, third.id])
    }

    private func makeProject(id: UUID, name: String) -> Project {
        Project(
            id: id,
            name: name,
            path: "/tmp/project-\(id.uuidString)",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
    }

    private func makeWorkspace(
        projectID: UUID,
        sessionIDs: [UUID],
        topSessionIDs: [UUID]? = nil,
        bottomTabSessionIDs: [UUID] = []
    ) -> ProjectWorkspace {
        let project = Project(
            id: projectID,
            name: "Project",
            path: "/tmp/project-\(projectID.uuidString)",
            shell: "/bin/zsh",
            defaultCommand: "",
            badgeText: nil,
            badgeSymbol: nil,
            badgeColorHex: nil,
            gitDefaultPushRemoteName: nil
        )
        let sessions = sessionIDs.map { sessionID in
            var session = TerminalSession.make(project: project, command: "")
            session.id = sessionID
            return session
        }
        let resolvedTopSessionIDs = topSessionIDs ?? sessionIDs
        return ProjectWorkspace(
            projectID: projectID,
            topSessionIDs: resolvedTopSessionIDs,
            topPaneRatios: Array(repeating: 1, count: resolvedTopSessionIDs.count),
            bottomTabSessionIDs: bottomTabSessionIDs,
            bottomPaneHeight: 240,
            selectedSessionID: resolvedTopSessionIDs.first ?? bottomTabSessionIDs[0],
            selectedBottomTabSessionID: bottomTabSessionIDs.last,
            sessions: sessions
        )
    }
}
