import Foundation
import XCTest
@testable import DmuxWorkspace

final class AppDiagnosticsExportServiceTests: XCTestCase {
    func testRedactedStateDataRemovesSSHSecrets() throws {
        let data = Data(
            """
            {
              "sshProfiles": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "password": "secret-password",
                  "keyPassphrase": "secret-passphrase",
                  "host": "example.com"
                }
              ],
              "other": "value"
            }
            """.utf8
        )

        let redacted = AppDiagnosticsExportService.redactedStateDataForDiagnostics(from: data)
        let text = String(data: redacted, encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains("secret-password"))
        XCTAssertFalse(text.contains("secret-passphrase"))
        XCTAssertTrue(text.contains(#""password" : "<redacted>""#))
        XCTAssertTrue(text.contains(#""keyPassphrase" : "<redacted>""#))
        XCTAssertTrue(text.contains(#""other" : "value""#))
    }
}
