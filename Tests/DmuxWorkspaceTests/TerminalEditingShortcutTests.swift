import AppKit
import XCTest
@testable import DmuxWorkspace

final class TerminalEditingShortcutTests: XCTestCase {
    func testCommandArrowMappings() {
        XCTAssertEqual(TerminalEditingShortcut.match(keyCode: 123, modifiers: [.command]), .beginningOfLine)
        XCTAssertEqual(TerminalEditingShortcut.match(keyCode: 124, modifiers: [.command]), .endOfLine)
    }

    func testOnlyCommandArrowMappingsAreEnabledForFallback() {
        XCTAssertNil(TerminalEditingShortcut.match(keyCode: 123, modifiers: [.option]))
        XCTAssertNil(TerminalEditingShortcut.match(keyCode: 124, modifiers: [.option]))
        XCTAssertNil(TerminalEditingShortcut.match(keyCode: 51, modifiers: [.command]))
        XCTAssertNil(TerminalEditingShortcut.match(keyCode: 51, modifiers: [.option]))
    }

    func testShortcutBytesMatchShellEditingSequences() {
        XCTAssertEqual(TerminalEditingShortcut.beginningOfLine.bytes, [0x01])
        XCTAssertEqual(TerminalEditingShortcut.endOfLine.bytes, [0x05])
    }
}
