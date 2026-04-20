import XCTest
import GhosttyTerminal
@testable import DmuxWorkspace

final class GhosttyResizeTransitionTests: XCTestCase {
    func testCapturePassesThroughWhenNotSuspended() {
        var state = GhosttyResizeTransitionState()
        let viewport = InMemoryTerminalViewport(columns: 120, rows: 30)

        XCTAssertEqual(state.capture(viewport), viewport)
    }

    func testSuspendedCaptureDefersUntilEnd() {
        var state = GhosttyResizeTransitionState()
        let first = InMemoryTerminalViewport(columns: 80, rows: 24)
        let second = InMemoryTerminalViewport(columns: 132, rows: 36)

        state.begin()

        XCTAssertNil(state.capture(first))
        XCTAssertNil(state.capture(second))
        XCTAssertEqual(state.end(), second)
        XCTAssertFalse(state.isSuspended)
    }

    func testEndClearsPendingViewport() {
        var state = GhosttyResizeTransitionState()
        let viewport = InMemoryTerminalViewport(columns: 100, rows: 28)

        state.begin()
        _ = state.capture(viewport)

        XCTAssertEqual(state.end(), viewport)
        XCTAssertNil(state.end())
    }
}
