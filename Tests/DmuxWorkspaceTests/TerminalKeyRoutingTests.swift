import AppKit
import XCTest
@testable import DmuxWorkspace

@MainActor
final class TerminalKeyRoutingTests: XCTestCase {
    func testFileBrowserShortcutsDoNotHandleTerminalResponder() {
        XCTAssertFalse(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                isActive: true,
                isInlineRenaming: false,
                hasWindow: true,
                eventWindowMatches: true,
                isTerminalResponder: true
            )
        )
    }

    func testFileBrowserShortcutsHandleOnlyActivePanelFocus() {
        XCTAssertTrue(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                isActive: true,
                isInlineRenaming: false,
                hasWindow: true,
                eventWindowMatches: true,
                isTerminalResponder: false
            )
        )
        XCTAssertFalse(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                isActive: false,
                isInlineRenaming: false,
                hasWindow: true,
                eventWindowMatches: true,
                isTerminalResponder: false
            )
        )
        XCTAssertFalse(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                isActive: true,
                isInlineRenaming: true,
                hasWindow: true,
                eventWindowMatches: true,
                isTerminalResponder: false
            )
        )
        XCTAssertFalse(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                isActive: true,
                isInlineRenaming: false,
                hasWindow: true,
                eventWindowMatches: false,
                isTerminalResponder: false
            )
        )
    }

    func testFileBrowserShortcutsIgnoreWorkspaceEditorFocus() {
        XCTAssertFalse(
            FileBrowserKeyboardFocusState.shouldHandleFileBrowserShortcut(
                context: .workspaceFileEditor(tabID: "/tmp/App.swift"),
                isActive: true,
                isInlineRenaming: false,
                hasWindow: true,
                eventWindowMatches: true,
                isTerminalResponder: false
            )
        )
    }

    func testMainMenuShortcutsAreNotRoutedToTerminalKeyDown() {
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: true,
                isReservedApplicationShortcut: false
            )
        )
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: true,
                isReservedApplicationShortcut: false
            )
        )
    }

    func testReservedApplicationShortcutsAreNotRoutedToTerminalKeyDown() {
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: true
            )
        )
    }

    func testWorkspaceEditorFocusIsNotRoutedToTerminalKeyDown() {
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false,
                isWorkspaceEditorFocused: true
            )
        )
    }

    func testWorkspaceKeyboardRouterUsesEditorResponderForFileCommands() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .terminal,
            isSelectedWorkspaceFilesModeActive: false,
            isSelectedWorkspaceReviewModeActive: false,
            isWorkspaceFileCommandActive: false,
            isTerminalResponder: false,
            isSystemTextResponder: false,
            responderClassName: "CodeEditSourceEditor.SourceEditorTextView"
        )

        XCTAssertEqual(scope, .fileEditor)
        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: nil,
                keyCode: 13,
                modifiers: [.command],
                scope: scope
            ),
            .closeFileTab
        )
        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: "s",
                keyCode: 1,
                modifiers: [.command],
                scope: scope
            ),
            .saveFileTab
        )
    }

    func testWorkspaceKeyboardRouterRecognizesCodeEditTextViewResponder() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .none,
            isSelectedWorkspaceFilesModeActive: false,
            isSelectedWorkspaceReviewModeActive: false,
            isWorkspaceFileCommandActive: false,
            isTerminalResponder: false,
            isSystemTextResponder: false,
            responderClassName: "CodeEditTextView.TextView"
        )

        XCTAssertEqual(scope, .fileEditor)
        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: "w",
                keyCode: 13,
                modifiers: [.command],
                scope: scope
            ),
            .closeFileTab
        )
    }

    func testWorkspaceKeyboardRouterKeepsGlobalShortcutsAboveFileEditor() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .workspaceFileEditor(tabID: "/tmp/App.swift"),
            isSelectedWorkspaceFilesModeActive: true,
            isSelectedWorkspaceReviewModeActive: false,
            isWorkspaceFileCommandActive: true,
            isTerminalResponder: false,
            isSystemTextResponder: false,
            responderClassName: "CodeEditSourceEditor.SourceEditorTextView"
        )

        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: "1",
                keyCode: 18,
                modifiers: [.command],
                scope: scope
            ),
            .passThrough
        )
    }

    func testWorkspaceKeyboardRouterRoutesTerminalCommandWToTerminalClose() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .terminal,
            isSelectedWorkspaceFilesModeActive: false,
            isSelectedWorkspaceReviewModeActive: false,
            isWorkspaceFileCommandActive: false,
            isTerminalResponder: true,
            isSystemTextResponder: false,
            responderClassName: "GhosttySurfaceView"
        )

        XCTAssertEqual(scope, .terminal)
        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: "w",
                keyCode: 13,
                modifiers: [.command],
                scope: scope
            ),
            .closeTerminalSplit
        )
    }

    func testWorkspaceKeyboardRouterLetsFileBrowserOwnFileManagementKeys() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .fileBrowser,
            isSelectedWorkspaceFilesModeActive: true,
            isSelectedWorkspaceReviewModeActive: false,
            isWorkspaceFileCommandActive: true,
            isTerminalResponder: false,
            isSystemTextResponder: false,
            responderClassName: "FileBrowserKeyboardBridgeView"
        )

        XCTAssertEqual(scope, .fileBrowser)
        XCTAssertTrue(
            WorkspaceKeyboardRouter.shouldPreferFileBrowserShortcut(
                key: "c",
                keyCode: 8,
                modifiers: [.command],
                scope: scope
            )
        )
        XCTAssertTrue(
            WorkspaceKeyboardRouter.shouldPreferFileBrowserShortcut(
                key: nil,
                keyCode: 51,
                modifiers: [],
                scope: scope
            )
        )
        XCTAssertFalse(
            WorkspaceKeyboardRouter.shouldPreferFileBrowserShortcut(
                key: "1",
                keyCode: 18,
                modifiers: [.command],
                scope: scope
            )
        )
    }

    func testWorkspaceReviewModeDoesNotUseTerminalOrFileTabCommandW() {
        let scope = WorkspaceKeyboardRouter.focusScope(
            focusContext: .terminal,
            isSelectedWorkspaceFilesModeActive: false,
            isSelectedWorkspaceReviewModeActive: true,
            isWorkspaceFileCommandActive: false,
            isTerminalResponder: true,
            isSystemTextResponder: false,
            responderClassName: "GhosttySurfaceView"
        )

        XCTAssertEqual(scope, .workspaceReview)
        XCTAssertEqual(
            WorkspaceKeyboardRouter.commandAction(
                key: "w",
                keyCode: 13,
                modifiers: [.command],
                scope: scope
            ),
            .passThrough
        )
    }

    func testNonMenuKeysStillRouteToTerminalKeyDown() {
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false
            )
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false
            )
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false
            )
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false
            )
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(
                isMainMenuShortcut: false,
                isReservedApplicationShortcut: false
            )
        )
    }
}
