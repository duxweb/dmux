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

    func testTopPaneStartupResizeDoesNotCommitRatiosWithoutUserDrag() {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

        XCTAssertFalse(
            TopPaneSplitController.shouldCommitTopPaneRatios(
                isApplyingLayout: false,
                hasAppliedInitialRatios: true,
                isUserDraggingDivider: false,
                isVisible: true,
                topSessionCount: 2,
                selectedWorktreeID: projectID,
                currentWorkspaceProjectID: projectID
            )
        )
    }

    func testTopPaneUserDragCommitsRatiosAfterInitialLayout() {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

        XCTAssertTrue(
            TopPaneSplitController.shouldCommitTopPaneRatios(
                isApplyingLayout: false,
                hasAppliedInitialRatios: true,
                isUserDraggingDivider: true,
                isVisible: true,
                topSessionCount: 2,
                selectedWorktreeID: projectID,
                currentWorkspaceProjectID: projectID
            )
        )
    }

    func testBottomSplitDividerPositionUsesBottomHeight() {
        let position = WorkspaceVerticalSplitMetrics.dividerPosition(
            forBottomHeight: 298,
            totalHeight: 900,
            hasBottomTabs: true
        )

        XCTAssertEqual(position, 298, accuracy: 0.001)
    }

    func testBottomSplitDividerPositionLeavesMinimumTopHeight() {
        let position = WorkspaceVerticalSplitMetrics.dividerPosition(
            forBottomHeight: 820,
            totalHeight: 900,
            hasBottomTabs: true
        )

        XCTAssertEqual(position, 900 - ProjectWorkspace.minimumTopPaneHeight, accuracy: 0.001)
    }

    func testBottomSplitDividerConstraintsMatchBottomCoordinate() {
        XCTAssertEqual(
            WorkspaceVerticalSplitMetrics.minimumDividerCoordinate(totalHeight: 900, hasBottomRegion: true, hasBottomTabs: true),
            ProjectWorkspace.minimumBottomPaneHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            WorkspaceVerticalSplitMetrics.maximumDividerCoordinate(totalHeight: 900, hasBottomRegion: true, hasBottomTabs: true),
            680,
            accuracy: 0.001
        )
    }

    func testCollapsedBottomDividerLocksToStatusBarHeight() {
        XCTAssertEqual(
            WorkspaceVerticalSplitMetrics.dividerPosition(
                forBottomHeight: BottomTabbedPaneView.statusBarHeight,
                totalHeight: 900,
                hasBottomTabs: false
            ),
            BottomTabbedPaneView.statusBarHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            WorkspaceVerticalSplitMetrics.minimumDividerCoordinate(totalHeight: 900, hasBottomRegion: true, hasBottomTabs: false),
            BottomTabbedPaneView.statusBarHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            WorkspaceVerticalSplitMetrics.maximumDividerCoordinate(totalHeight: 900, hasBottomRegion: true, hasBottomTabs: false),
            BottomTabbedPaneView.statusBarHeight,
            accuracy: 0.001
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

    func testWorkspaceLayoutPersistenceResetsToLaunchDefaults() throws {
        let first = UUID(uuidString: "50000000-0000-0000-0000-000000000011")!
        let second = UUID(uuidString: "50000000-0000-0000-0000-000000000012")!
        let third = UUID(uuidString: "50000000-0000-0000-0000-000000000013")!
        var workspace = makeWorkspace(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            sessionIDs: [first, second, third],
            topSessionIDs: [first, second],
            bottomTabSessionIDs: [third]
        )
        workspace.topPaneRatios = [0.2, 0.8]
        workspace.bottomPaneHeight = 640

        let data = try JSONEncoder().encode(workspace)
        let restored = try JSONDecoder().decode(ProjectWorkspace.self, from: data)

        XCTAssertEqual(restored.resolvedTopPaneRatios(), [0.5, 0.5])
        XCTAssertEqual(restored.bottomPaneHeight, ProjectWorkspace.defaultBottomPaneHeight, accuracy: 0.001)
    }

    func testAppModelLaunchResetsPersistedWorkspaceLayout() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!, name: "Root")
        let first = UUID(uuidString: "50000000-0000-0000-0000-000000000021")!
        let second = UUID(uuidString: "50000000-0000-0000-0000-000000000022")!
        let third = UUID(uuidString: "50000000-0000-0000-0000-000000000023")!
        var workspace = makeWorkspace(
            projectID: root.id,
            sessionIDs: [first, second, third],
            topSessionIDs: [first, second],
            bottomTabSessionIDs: [third]
        )
        workspace.topPaneRatios = [0.18, 0.82]
        workspace.bottomPaneHeight = 650
        let snapshot = AppSnapshot(
            projects: [root],
            worktrees: [ProjectWorktree.defaultWorktree(for: root)],
            workspaces: [workspace],
            selectedProjectID: root.id,
            selectedWorktreeID: root.id,
            workspaceContentStates: nil,
            appSettings: nil,
            taskMemos: nil,
            sshProfiles: nil
        )

        let model = AppModel(snapshot: snapshot, persistenceService: PersistenceService())

        XCTAssertEqual(model.selectedWorkspace?.resolvedTopPaneRatios(), [0.5, 0.5])
        XCTAssertEqual(model.selectedWorkspace?.bottomPaneHeight, ProjectWorkspace.defaultBottomPaneHeight)
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

    func testSnapshotMigrationCreatesDefaultWorktree() {
        let project = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!, name: "Legacy")
        let snapshot = AppSnapshot(
            projects: [project],
            worktrees: nil,
            workspaces: [makeWorkspace(projectID: project.id, sessionIDs: [UUID()])],
            selectedProjectID: project.id,
            selectedWorktreeID: nil,
            appSettings: nil,
            taskMemos: nil,
            sshProfiles: nil
        )

        let model = AppModel(snapshot: snapshot, persistenceService: PersistenceService())

        XCTAssertEqual(model.worktrees.count, 1)
        XCTAssertEqual(model.worktrees.first?.id, project.id)
        XCTAssertEqual(model.worktrees.first?.projectID, project.id)
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertEqual(model.selectedWorktreeID, project.id)
        XCTAssertEqual(model.selectedWorkspace?.projectID, project.id)
    }

    func testSelectingWorktreeUsesWorktreeWorkspace() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "feature",
            branch: "feature/worktree",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [
            ProjectWorktree.defaultWorktree(for: root),
            feature,
        ]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: feature.id, sessionIDs: [UUID()]),
        ]

        model.selectWorktree(feature.id)

        XCTAssertEqual(model.selectedProjectID, root.id)
        XCTAssertEqual(model.selectedWorktreeID, feature.id)
        XCTAssertEqual(model.selectedProject?.id, feature.id)
        XCTAssertEqual(model.selectedWorkspace?.projectID, feature.id)
    }

    func testWorktreeTaskSnapshotRestoresTask() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Review editor",
            branch: "task/review-editor",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Review editor",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .running,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: nil
        )
        let snapshot = AppSnapshot(
            projects: [root],
            worktrees: [ProjectWorktree.defaultWorktree(for: root), feature],
            worktreeTasks: [task],
            workspaces: [
                makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
                makeWorkspace(projectID: featureID, sessionIDs: [sessionID]),
            ],
            selectedProjectID: root.id,
            selectedWorktreeID: featureID,
            appSettings: nil,
            taskMemos: nil,
            sshProfiles: nil
        )

        let model = AppModel(snapshot: snapshot, persistenceService: PersistenceService())

        XCTAssertEqual(model.worktreeTask(featureID)?.title, "Review editor")
        XCTAssertEqual(model.worktreeStatusSummary(for: root.id), "1 Running")
    }

    func testWorktreeEffectiveStatusUsesLiveRuntimeBeforePersistedTodo() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000307")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000308")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000309")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Runtime task",
            branch: "task/runtime",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .todo,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Runtime task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .todo,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [sessionID]),
        ]
        model.worktreeTasks = [task]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .promptSubmitted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: featureID,
                    projectName: "Root · Runtime task",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-runtime-session",
                    model: "gpt-5.5",
                    totalTokens: 10,
                    updatedAt: 100,
                    metadata: nil
                )
            )
        )

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .todo)
        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: feature), .running)
        XCTAssertTrue(model.isWorktreeAIActive(for: feature))
        XCTAssertEqual(model.worktreeStatusSummary(for: root.id), "1 Running")
    }

    func testDefaultWorktreeUsesLiveRuntimeForMainTaskActivity() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!, name: "Root")
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
        let defaultWorktree = ProjectWorktree.defaultWorktree(for: root)
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [defaultWorktree]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [sessionID])
        ]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .promptSubmitted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-main",
                    projectID: root.id,
                    projectName: "Root",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-main-session",
                    model: "gpt-5.5",
                    totalTokens: 10,
                    updatedAt: 100,
                    metadata: nil
                )
            )
        )

        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: defaultWorktree), .running)
        XCTAssertTrue(model.isWorktreeAIActive(for: defaultWorktree))
    }

    func testProjectActivityAggregatesRunningWorktreeAIAndCountsMultipleActiveTasks() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000310")!, name: "Root")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
        let firstSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000313")!
        let secondSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000314")!
        let first = ProjectWorktree(
            id: firstID,
            projectID: root.id,
            name: "First task",
            branch: "task/first",
            path: "/tmp/project-\(firstID.uuidString)",
            status: .todo,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let second = ProjectWorktree(
            id: secondID,
            projectID: root.id,
            name: "Second task",
            branch: "task/second",
            path: "/tmp/project-\(secondID.uuidString)",
            status: .todo,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let firstTask = WorktreeTask(
            worktreeID: firstID,
            title: "First task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .todo,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
        let secondTask = WorktreeTask(
            worktreeID: secondID,
            title: "Second task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .todo,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), first, second]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: firstID, sessionIDs: [firstSessionID]),
            makeWorkspace(projectID: secondID, sessionIDs: [secondSessionID]),
        ]
        model.worktreeTasks = [firstTask, secondTask]
        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .promptSubmitted,
                    terminalID: firstSessionID,
                    terminalInstanceID: "instance-1",
                    projectID: firstID,
                    projectName: "Root · First task",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-first-session",
                    model: "gpt-5.5",
                    totalTokens: 10,
                    updatedAt: 100,
                    metadata: nil
                )
            )
        )
        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .promptSubmitted,
                    terminalID: secondSessionID,
                    terminalInstanceID: "instance-2",
                    projectID: secondID,
                    projectName: "Root · Second task",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-second-session",
                    model: "gpt-5.5",
                    totalTokens: 12,
                    updatedAt: 101,
                    metadata: nil
                )
            )
        )

        let phase = model.resolvedProjectActivityPhase(projectID: root.id)
        XCTAssertEqual(phase, .running(tool: "codex"))
        XCTAssertEqual(model.activityIndicatorCount(for: root.id, phase: phase), 2)
        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: first), .running)
        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: second), .running)
    }

    func testProjectCompletionPromptFromWorktreeStaysDismissedWhileTaskPendingReview() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000315")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000316")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000317")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Completed task",
            branch: "task/completed",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Completed task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .running,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [sessionID]),
        ]
        model.worktreeTasks = [task]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .turnCompleted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: featureID,
                    projectName: "Root · Completed task",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-completed-session",
                    model: "gpt-5.5",
                    totalTokens: 20,
                    updatedAt: 101,
                    metadata: nil
                )
            )
        )
        model.refreshProjectActivity(sendNotifications: true)

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .done)
        XCTAssertEqual(
            model.resolvedProjectActivityPhase(projectID: root.id),
            .completed(tool: "codex", finishedAt: Date(timeIntervalSince1970: 101), exitCode: nil)
        )
        XCTAssertTrue(model.dismissCompletionPresentationIfNeeded(projectID: root.id, reason: "test"))
        XCTAssertEqual(model.resolvedProjectActivityPhase(projectID: root.id), .idle)
        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: feature), .done)

        model.refreshProjectActivity(sendNotifications: true)

        XCTAssertEqual(model.resolvedProjectActivityPhase(projectID: root.id), .idle)
    }

    func testProjectCompletionWaitsUntilAllActiveTaskWorktreesAreComplete() {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000318")!, name: "Root")
        let completedID = UUID(uuidString: "00000000-0000-0000-0000-000000000319")!
        let pendingID = UUID(uuidString: "00000000-0000-0000-0000-000000000320")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let completed = ProjectWorktree(
            id: completedID,
            projectID: root.id,
            name: "Completed task",
            branch: "task/completed",
            path: "/tmp/project-\(completedID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let pending = ProjectWorktree(
            id: pendingID,
            projectID: root.id,
            name: "Pending task",
            branch: "task/pending",
            path: "/tmp/project-\(pendingID.uuidString)",
            status: .todo,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let completedTask = WorktreeTask(
            worktreeID: completedID,
            title: "Completed task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .running,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: nil
        )
        let pendingTask = WorktreeTask(
            worktreeID: pendingID,
            title: "Pending task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .todo,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), completed, pending]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: completedID, sessionIDs: [sessionID]),
            makeWorkspace(projectID: pendingID, sessionIDs: [UUID()]),
        ]
        model.worktreeTasks = [completedTask, pendingTask]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .turnCompleted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: completedID,
                    projectName: "Root · Completed task",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-completed-session",
                    model: "gpt-5.5",
                    totalTokens: 20,
                    updatedAt: 101,
                    metadata: nil
                )
            )
        )
        model.refreshProjectActivity(sendNotifications: true)

        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: completed), .done)
        XCTAssertEqual(model.effectiveWorktreeTaskStatus(for: pending), .todo)
        XCTAssertEqual(model.resolvedProjectActivityPhase(projectID: root.id), .idle)
        XCTAssertNil(model.activityIndicatorCount(for: root.id, phase: .completed(tool: "codex", finishedAt: Date(timeIntervalSince1970: 101), exitCode: nil)))
    }

    func testWorkspaceFilesModeCanBeSelectedWithoutOpenTabs() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!, name: "Root")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .terminal)

        model.selectWorkspaceFiles()

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .files)
        XCTAssertNil(model.selectedWorkspaceFileTab(for: root.id))
    }

    func testWorkspaceReviewModeCanBeSelectedWithoutRightPanel() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!, name: "Root")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.selectWorkspaceReview()

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .review)
        XCTAssertEqual(model.selectedWorktreeReviewID, root.id)
        XCTAssertNil(model.rightPanel)
    }

    func testWorktreeSidebarExpansionTogglesInMemory() {
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())

        XCTAssertTrue(model.isWorktreeSidebarExpanded)

        model.toggleWorktreeSidebarExpansion()
        XCTAssertFalse(model.isWorktreeSidebarExpanded)

        model.toggleWorktreeSidebarExpansion()
        XCTAssertTrue(model.isWorktreeSidebarExpanded)
    }

    func testOpeningDefaultWorktreeReviewUsesWorkingTreeAuditMode() async {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000505")!, name: "Root")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openWorktreeReview(root.id)

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .review)
        XCTAssertEqual(model.selectedWorktreeReviewID, root.id)
        let didLoadAuditSnapshot = await waitFor { model.worktreeReviewSnapshot?.mode == .workingTreeAudit }
        XCTAssertTrue(didLoadAuditSnapshot)
    }

    func testTerminalModeDoesNotDiscardSelectedWorkspaceFileTab() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/App.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(fileURL, rootURL: rootURL)
        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .files)
        XCTAssertEqual(model.selectedWorkspaceFileTab(for: root.id)?.id, fileURL.standardizedFileURL.path)

        model.selectWorkspaceTerminal()

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .terminal)
        XCTAssertEqual(model.selectedWorkspaceFileTab(for: root.id)?.id, fileURL.standardizedFileURL.path)
    }

    func testReviewModeDoesNotDiscardSelectedWorkspaceFileTab() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/App.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(fileURL, rootURL: rootURL)
        model.selectWorkspaceReview()

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .review)
        XCTAssertEqual(model.selectedWorkspaceFileTab(for: root.id)?.id, fileURL.standardizedFileURL.path)
    }

    func testWorkspaceContentStateRestoresReviewModeAsTerminal() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!, name: "Root")
        let snapshot = AppSnapshot(
            projects: [root],
            worktrees: [ProjectWorktree.defaultWorktree(for: root)],
            workspaces: [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])],
            selectedProjectID: root.id,
            selectedWorktreeID: root.id,
            workspaceContentStates: [
                WorkspaceContentState(
                    worktreeID: root.id,
                    primaryViewMode: .review,
                    selectedFileTabID: nil,
                    fileTabs: []
                )
            ],
            appSettings: nil,
            taskMemos: nil,
            sshProfiles: nil
        )

        let model = AppModel(snapshot: snapshot, persistenceService: PersistenceService())

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .terminal)
        XCTAssertNil(model.selectedWorktreeReviewID)
    }

    func testWorkspaceContentStateRestoresFileModeAndTabs() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/App.swift")
        let tab = WorkspaceFileTab(fileURL: fileURL, rootURL: rootURL, title: "App.swift")
        let snapshot = AppSnapshot(
            projects: [root],
            worktrees: [ProjectWorktree.defaultWorktree(for: root)],
            workspaces: [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])],
            selectedProjectID: root.id,
            selectedWorktreeID: root.id,
            workspaceContentStates: [
                WorkspaceContentState(
                    worktreeID: root.id,
                    primaryViewMode: .files,
                    selectedFileTabID: tab.id,
                    fileTabs: [tab]
                )
            ],
            appSettings: nil,
            taskMemos: nil,
            sshProfiles: nil
        )

        let model = AppModel(snapshot: snapshot, persistenceService: PersistenceService())

        XCTAssertEqual(model.workspacePrimaryViewMode(for: root.id), .files)
        XCTAssertEqual(model.workspaceFileTabs(for: root.id).map(\.id), [tab.id])
        XCTAssertEqual(model.selectedWorkspaceFileTab(for: root.id)?.id, tab.id)
    }

    func testWorkspaceContentStateSnapshotPreservesSelectedFileWhenTerminalModeSelected() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000404")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/App.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(fileURL, rootURL: rootURL)
        model.selectWorkspaceTerminal()

        let state = model.workspaceContentStatesSnapshot()?.first
        XCTAssertEqual(state?.worktreeID, root.id)
        XCTAssertEqual(state?.primaryViewMode, .terminal)
        XCTAssertEqual(state?.selectedFileTabID, fileURL.standardizedFileURL.path)
        XCTAssertEqual(state?.fileTabs.map(\.id), [fileURL.standardizedFileURL.path])
    }

    func testWorkspaceContentStateSnapshotDoesNotPersistReviewMode() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000504")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/App.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(fileURL, rootURL: rootURL)
        model.selectWorkspaceReview()

        let state = model.workspaceContentStatesSnapshot()?.first
        XCTAssertEqual(state?.worktreeID, root.id)
        XCTAssertEqual(state?.primaryViewMode, .terminal)
        XCTAssertEqual(state?.selectedFileTabID, fileURL.standardizedFileURL.path)
        XCTAssertEqual(state?.fileTabs.map(\.id), [fileURL.standardizedFileURL.path])
    }

    func testWorkspaceFileEditorSaveRequestTargetsSelectedTab() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000405")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let firstURL = rootURL.appendingPathComponent("Sources/App.swift")
        let secondURL = rootURL.appendingPathComponent("Sources/Model.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(firstURL, rootURL: rootURL)
        model.openFileInWorkspace(secondURL, rootURL: rootURL)

        XCTAssertTrue(model.requestSaveSelectedWorkspaceFileTab())
        XCTAssertEqual(model.workspaceFileEditorSaveRequestToken(for: firstURL.standardizedFileURL.path), 0)
        XCTAssertEqual(model.workspaceFileEditorSaveRequestToken(for: secondURL.standardizedFileURL.path), 1)
    }

    func testCloseSelectedWorkspaceFileTabClosesCurrentFileNotTerminal() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000406")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let firstURL = rootURL.appendingPathComponent("Sources/App.swift")
        let secondURL = rootURL.appendingPathComponent("Sources/Model.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(firstURL, rootURL: rootURL)
        model.openFileInWorkspace(secondURL, rootURL: rootURL)

        XCTAssertTrue(model.closeSelectedWorkspaceFileTab())
        XCTAssertEqual(model.workspaceFileTabs(for: root.id).map(\.id), [firstURL.standardizedFileURL.path])
        XCTAssertEqual(model.selectedWorkspaceFileTab(for: root.id)?.id, firstURL.standardizedFileURL.path)
        XCTAssertEqual(model.selectedWorkspace?.sessions.count, 1)
    }

    func testWorkspaceFileCommandClosesActiveEditorTabEvenIfModeIsStale() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000407")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let firstURL = rootURL.appendingPathComponent("Sources/App.swift")
        let secondURL = rootURL.appendingPathComponent("Sources/Model.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(firstURL, rootURL: rootURL)
        model.openFileInWorkspace(secondURL, rootURL: rootURL)
        model.selectWorkspaceTerminal()
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: secondURL.standardizedFileURL.path)
        defer { FileBrowserKeyboardFocusState.activateTerminal() }

        XCTAssertTrue(model.closeWorkspaceFileCommandTab())
        XCTAssertEqual(model.workspaceFileTabs(for: root.id).map(\.id), [firstURL.standardizedFileURL.path])
        XCTAssertEqual(model.selectedWorkspace?.sessions.count, 1)
    }

    func testWorkspaceFileCommandSaveTargetsActiveEditorTabEvenIfModeIsStale() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000408")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let firstURL = rootURL.appendingPathComponent("Sources/App.swift")
        let secondURL = rootURL.appendingPathComponent("Sources/Model.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [UUID()])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(firstURL, rootURL: rootURL)
        model.openFileInWorkspace(secondURL, rootURL: rootURL)
        model.selectWorkspaceTerminal()
        FileBrowserKeyboardFocusState.activateWorkspaceFileEditor(tabID: secondURL.standardizedFileURL.path)
        defer { FileBrowserKeyboardFocusState.activateTerminal() }

        XCTAssertTrue(model.requestSaveWorkspaceFileCommandTab())
        XCTAssertEqual(model.workspaceFileEditorSaveRequestToken(for: firstURL.standardizedFileURL.path), 0)
        XCTAssertEqual(model.workspaceFileEditorSaveRequestToken(for: secondURL.standardizedFileURL.path), 1)
    }

    func testWorkspaceFileSaveAndCloseCompletionClosesFileTabOnly() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000409")!, name: "Root")
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let firstURL = rootURL.appendingPathComponent("Sources/App.swift")
        let secondURL = rootURL.appendingPathComponent("Sources/Model.swift")
        let secondTabID = secondURL.standardizedFileURL.path
        let sessionID = UUID()
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root)]
        model.workspaces = [makeWorkspace(projectID: root.id, sessionIDs: [sessionID])]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id

        model.openFileInWorkspace(firstURL, rootURL: rootURL)
        model.openFileInWorkspace(secondURL, rootURL: rootURL)
        model.setWorkspaceFileTabDirty(secondTabID, isDirty: true)
        model.workspaceFileEditorSaveRequestTokensByTabID[secondTabID] = 1
        model.workspaceFileEditorSaveAndCloseRequestTokensByTabID[secondTabID] = 1

        XCTAssertTrue(model.closeWorkspaceFileTabAfterSaving(tabID: secondTabID))

        XCTAssertEqual(model.workspaceFileTabs(for: root.id).map(\.id), [firstURL.standardizedFileURL.path])
        XCTAssertFalse(model.isWorkspaceFileTabDirty(secondTabID))
        XCTAssertEqual(model.workspaceFileEditorSaveRequestToken(for: secondTabID), 0)
        XCTAssertEqual(model.workspaceFileEditorSaveAndCloseRequestToken(for: secondTabID), 0)
        XCTAssertEqual(model.selectedWorkspace?.sessions.map(\.id), [sessionID])
    }

    func testWorkspaceFileCommandFallsBackToVisibleFilesModeTab() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000410")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000411")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "feature",
            branch: "feature/files",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rootURL = URL(fileURLWithPath: feature.path, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("Sources/Feature.swift")
        let tab = WorkspaceFileTab(fileURL: fileURL, rootURL: rootURL, title: "Feature.swift")
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: feature.id, sessionIDs: [UUID()]),
        ]
        model.selectedProjectID = root.id
        model.selectedWorktreeID = root.id
        model.workspaceFileTabsByWorktreeID[feature.id] = [tab]
        model.workspacePrimaryViewModeByWorktreeID[feature.id] = .files
        model.selectedWorkspaceContentByWorktreeID[feature.id] = .file(tab.id)
        FileBrowserKeyboardFocusState.clearWorkspaceFileEditor(tabID: nil)

        XCTAssertTrue(model.closeWorkspaceFileCommandTab())
        XCTAssertEqual(model.workspaceFileTabs(for: feature.id), [])
    }

    func testWorktreeRuntimeCompletionMarksTaskDone() throws {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000420")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000421")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000422")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Review editor",
            branch: "task/review-editor",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .running,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Review editor",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .running,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [sessionID]),
        ]
        model.worktreeTasks = [task]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .promptSubmitted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: featureID,
                    projectName: "Root · Review editor",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-worktree-session",
                    model: "gpt-5.5",
                    totalTokens: 10,
                    updatedAt: 100,
                    metadata: nil
                )
            )
        )
        model.syncWorktreeTaskStatusesFromRuntime()

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .running)

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .turnCompleted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: featureID,
                    projectName: "Root · Review editor",
                    sessionTitle: "Codex",
                    tool: "codex",
                    aiSessionID: "codex-worktree-session",
                    model: "gpt-5.5",
                    totalTokens: 20,
                    updatedAt: 101,
                    metadata: nil
                )
            )
        )
        model.syncWorktreeTaskStatusesFromRuntime()

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .done)
        XCTAssertEqual(model.worktrees.first(where: { $0.id == featureID })?.status, .done)
        XCTAssertNotNil(model.worktreeTask(featureID)?.completedAt)
    }

    func testOpeningWorktreeReviewKeepsTodoTaskStatus() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000426")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000427")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Todo task",
            branch: "task/todo",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .todo,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Todo task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .todo,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: nil,
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.worktreeTasks = [task]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [UUID()]),
        ]

        model.openWorktreeReview(featureID)

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .todo)
        XCTAssertEqual(model.worktrees.first(where: { $0.id == featureID })?.status, .todo)
        XCTAssertEqual(model.workspacePrimaryViewMode(for: featureID), .review)
        XCTAssertEqual(model.selectedWorktreeReviewID, featureID)
        XCTAssertNil(model.rightPanel)
    }

    func testOpeningWorktreeReviewPromotesReadyTaskToReview() {
        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000428")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000429")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Ready task",
            branch: "task/ready",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .ready,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Ready task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .ready,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: Date()
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.worktreeTasks = [task]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [UUID()]),
        ]

        model.openWorktreeReview(featureID)

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .review)
        XCTAssertEqual(model.worktrees.first(where: { $0.id == featureID })?.status, .review)
        XCTAssertEqual(model.workspacePrimaryViewMode(for: featureID), .review)
        XCTAssertEqual(model.selectedWorktreeReviewID, featureID)
        XCTAssertNil(model.rightPanel)
    }

    func testOnlyReviewableWorktreeStatusesCanMerge() {
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())

        XCTAssertTrue(model.isWorktreeMergeCandidateStatus(.ready))
        XCTAssertTrue(model.isWorktreeMergeCandidateStatus(.review))
        XCTAssertTrue(model.isWorktreeMergeCandidateStatus(.done))
        XCTAssertTrue(model.isWorktreeMergeCandidateStatus(.blocked))

        XCTAssertFalse(model.isWorktreeMergeCandidateStatus(.todo))
        XCTAssertFalse(model.isWorktreeMergeCandidateStatus(.running))
        XCTAssertFalse(model.isWorktreeMergeCandidateStatus(.waiting))
        XCTAssertFalse(model.isWorktreeMergeCandidateStatus(.merged))
        XCTAssertFalse(model.isWorktreeMergeCandidateStatus(.archived))
    }

    func testWorktreeReviewRuntimeCompletionKeepsTaskInReview() throws {
        AISessionStore.shared.reset()
        defer { AISessionStore.shared.reset() }

        let root = makeProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000440")!, name: "Root")
        let featureID = UUID(uuidString: "00000000-0000-0000-0000-000000000441")!
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000442")!
        let feature = ProjectWorktree(
            id: featureID,
            projectID: root.id,
            name: "Review task",
            branch: "task/review-task",
            path: "/tmp/project-\(featureID.uuidString)",
            status: .review,
            isDefault: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = WorktreeTask(
            worktreeID: featureID,
            title: "Review task",
            baseBranch: "main",
            baseCommit: "abc123",
            status: .review,
            createdAt: Date(),
            updatedAt: Date(),
            startedAt: Date(),
            completedAt: nil
        )
        let model = AppModel(snapshot: nil, persistenceService: PersistenceService())
        model.projects = [root]
        model.worktrees = [ProjectWorktree.defaultWorktree(for: root), feature]
        model.workspaces = [
            makeWorkspace(projectID: root.id, sessionIDs: [UUID()]),
            makeWorkspace(projectID: featureID, sessionIDs: [sessionID]),
        ]
        model.worktreeTasks = [task]

        XCTAssertTrue(
            AISessionStore.shared.apply(
                AIHookEvent(
                    kind: .turnCompleted,
                    terminalID: sessionID,
                    terminalInstanceID: "instance-1",
                    projectID: featureID,
                    projectName: "Root · Review task",
                    sessionTitle: "Codex Review",
                    tool: "codex",
                    aiSessionID: "codex-review-session",
                    model: "gpt-5.5",
                    totalTokens: 20,
                    updatedAt: 101,
                    metadata: nil
                )
            )
        )
        model.syncWorktreeTaskStatusesFromRuntime()

        XCTAssertEqual(model.worktreeTask(featureID)?.status, .review)
        XCTAssertEqual(model.worktrees.first(where: { $0.id == featureID })?.status, .review)
        XCTAssertEqual(model.worktreeStatusSummary(for: root.id), "1 Review")
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
            bottomPaneHeight: ProjectWorkspace.defaultBottomPaneHeight,
            selectedSessionID: resolvedTopSessionIDs.first ?? bottomTabSessionIDs[0],
            selectedBottomTabSessionID: bottomTabSessionIDs.last,
            sessions: sessions
        )
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
