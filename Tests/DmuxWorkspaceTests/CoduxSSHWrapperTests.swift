import Foundation
import XCTest
@testable import DmuxWorkspace

final class CoduxSSHWrapperTests: XCTestCase {
    func testWrapperExecutesSSHFromSavedProfile() throws {
        let fixture = try makeFixture(
            state: """
            {"sshProfiles":[{"id":"11111111-1111-1111-1111-111111111111","host":"example.com","port":2222,"username":"root","credentialKind":"none","privateKeyPath":""}]}
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try runWrapper(profileID: "11111111-1111-1111-1111-111111111111", fixture: fixture)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("SSH_ARGS<-p><2222><root@example.com>\n"))
        XCTAssertTrue(result.stdout.contains("SSH_LOCALE LANG=<unset> LC_CTYPE=<unset> LC_ALL=<unset>"))
        XCTAssertEqual(result.stderr, "")
    }

    func testWrapperDoesNotForwardLocalLocaleToSSH() throws {
        let fixture = try makeFixture(
            state: """
            {"sshProfiles":[{"id":"33333333-3333-3333-3333-333333333333","host":"example.org","port":22,"username":"root","credentialKind":"none","privateKeyPath":""}]}
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try runWrapper(
            profileID: "33333333-3333-3333-3333-333333333333",
            fixture: fixture,
            extraEnvironment: [
                "LANG": "zh_CN.UTF-8",
                "LC_CTYPE": "zh_CN.UTF-8",
                "LC_ALL": "zh_CN.UTF-8",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("SSH_LOCALE LANG=<unset> LC_CTYPE=<unset> LC_ALL=<unset>"))
        XCTAssertEqual(result.stderr, "")
    }

    func testWrapperUsesExpectHelperForSavedPasswordWithoutPastingScript() throws {
        let fixture = try makeFixture(
            state: """
            {"sshProfiles":[{"id":"22222222-2222-2222-2222-222222222222","host":"example.net","port":22,"username":"deploy","credentialKind":"password","privateKeyPath":"","password":"secret"}]}
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try runWrapper(profileID: "22222222-2222-2222-2222-222222222222", fixture: fixture)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("EXPECT_ARGS"))
        XCTAssertTrue(result.stdout.contains("codux-ssh-expect.exp"))
        XCTAssertTrue(result.stdout.contains("<\(fixture.fakeBinURL.appendingPathComponent("ssh").path)>"))
        XCTAssertTrue(result.stdout.contains("<-p><22><deploy@example.net>"))
        XCTAssertTrue(result.stdout.contains(" PASSWORD=secret PASSPHRASE=\n"))
        XCTAssertEqual(result.stderr, "")
    }

    private struct Fixture {
        var rootURL: URL
        var fakeBinURL: URL
        var stateFileURL: URL
    }

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func makeFixture(state: String) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codux-ssh-wrapper-\(UUID().uuidString)", isDirectory: true)
        let fakeBinURL = rootURL.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)

        let sshURL = fakeBinURL.appendingPathComponent("ssh", isDirectory: false)
        try """
        #!/bin/sh
        printf 'SSH_ARGS'
        for arg in "$@"; do printf '<%s>' "$arg"; done
        printf '\\nSSH_LOCALE LANG=%s LC_CTYPE=%s LC_ALL=%s\\n' "${LANG:-<unset>}" "${LC_CTYPE:-<unset>}" "${LC_ALL:-<unset>}"
        """.write(to: sshURL, atomically: true, encoding: .utf8)

        let expectURL = fakeBinURL.appendingPathComponent("expect", isDirectory: false)
        try """
        #!/bin/sh
        printf 'EXPECT_ARGS'
        for arg in "$@"; do printf '<%s>' "$arg"; done
        printf ' PASSWORD=%s PASSPHRASE=%s\\n' "$CODUX_SSH_PASSWORD" "$CODUX_SSH_KEY_PASSPHRASE"
        """.write(to: expectURL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: expectURL.path)

        let stateFileURL = rootURL.appendingPathComponent("state.json", isDirectory: false)
        try state.write(to: stateFileURL, atomically: true, encoding: .utf8)

        return Fixture(rootURL: rootURL, fakeBinURL: fakeBinURL, stateFileURL: stateFileURL)
    }

    private func runWrapper(profileID: String, fixture: Fixture, extraEnvironment: [String: String] = [:]) throws -> ProcessResult {
        let wrapperURL = WorkspacePaths.repositoryResourceURL("scripts/wrappers/bin/codux-ssh")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [wrapperURL.path, profileID]
        var environment = [
            "PATH": "\(fixture.fakeBinURL.path):/usr/bin:/bin",
            "CODUX_STATE_FILE": fixture.stateFileURL.path,
        ]
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
