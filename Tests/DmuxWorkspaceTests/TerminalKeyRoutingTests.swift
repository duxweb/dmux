import AppKit
import XCTest
@testable import DmuxWorkspace

final class TerminalKeyRoutingTests: XCTestCase {
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
