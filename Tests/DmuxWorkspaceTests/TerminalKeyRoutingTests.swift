import AppKit
import XCTest
@testable import DmuxWorkspace

final class TerminalKeyRoutingTests: XCTestCase {
    func testCommandShortcutsAreNotRoutedToTerminalKeyDown() {
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [.command])
        )
        XCTAssertFalse(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [.command, .shift])
        )
    }

    func testNonCommandKeysStillRouteToTerminalKeyDown() {
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [])
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [.shift])
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [.option])
        )
        XCTAssertTrue(
            TerminalKeyRoutingPolicy.shouldRouteToTerminal(modifiers: [.control])
        )
    }
}
