import Foundation
import XCTest
@testable import DmuxWorkspace

final class GhosttyPTYProcessBridgeTests: XCTestCase {
    func testLargeInputWaitsForPtyBackpressureInsteadOfDroppingTail() throws {
        let byteCount = 256 * 1024
        let bridge = GhosttyPTYProcessBridge(sessionID: UUID())
        defer { bridge.terminateProcessTree() }

        let command = """
        stty raw -echo
        printf 'READY\\r\\n'
        sleep 0.25
        head -c \(byteCount) | wc -c
        printf '\\r\\nDONE\\r\\n'
        """
        bridge.start(
            shell: "/bin/sh",
            shellName: "sh",
            command: command,
            cwd: FileManager.default.temporaryDirectory.path,
            environment: [("TERM", "xterm-256color")]
        )

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                bridge.outputHistoryText().contains("READY")
            },
            "test process did not become ready"
        )

        bridge.sendText(String(repeating: "x", count: byteCount))

        XCTAssertTrue(
            waitUntil(timeout: 8) {
                let output = bridge.outputHistoryText()
                return output.contains("\(byteCount)") && output.contains("DONE")
            },
            "large input was not fully delivered through the PTY"
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
