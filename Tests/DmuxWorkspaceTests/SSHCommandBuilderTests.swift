import XCTest
@testable import DmuxWorkspace

final class SSHCommandBuilderTests: XCTestCase {
    func testLaunchCommandUsesInternalHelperWithoutEmbeddingCredentials() {
        let profileID = UUID()
        let profile = SSHConnectionProfile(
            id: profileID,
            name: "Production",
            host: "example.com",
            port: 22,
            username: "root",
            credentialKind: .password,
            privateKeyPath: "",
            updatedAt: Date(),
            password: "secret-password",
            keyPassphrase: nil
        )

        let launch = SSHCommandBuilder.launchCommand(for: profile)

        XCTAssertEqual(launch.command, "codux-ssh \(shellQuoted(profileID.uuidString))")
        XCTAssertEqual(launch.logCommand, launch.command)
        XCTAssertFalse(launch.command.contains("secret-password"))
        XCTAssertFalse(launch.command.contains("expect"))
        XCTAssertFalse(launch.command.contains("tmp_script"))
    }
}
