import XCTest
@testable import DmuxWorkspace

final class GhosttyEmbeddedConfigTests: XCTestCase {
    func testPrefersModernGhosttyConfigFileWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty/config",
            isDirectory: false
        )
        let modern = root.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: modern.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)
        try "modern".write(to: modern, atomically: true, encoding: .utf8)

        let resolved = GhosttyEmbeddedConfig.resolvedUserConfigFileURL(
            homeDirectoryURL: root
        )
        XCTAssertEqual(resolved?.path, modern.path)
    }

    func testFallsBackToLegacyGhosttyConfigFileWhenNeeded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty/config",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)

        let resolved = GhosttyEmbeddedConfig.resolvedUserConfigFileURL(
            homeDirectoryURL: root
        )
        XCTAssertEqual(resolved?.path, legacy.path)
    }

    func testEmbeddedDefaultConfigurationIncludesMacEditingBindings() {
        let rendered = GhosttyEmbeddedConfig.fallbackEditingConfigContents()

        XCTAssertTrue(rendered.contains("keybind = cmd+left=text:\\x01"))
        XCTAssertTrue(rendered.contains("keybind = cmd+right=text:\\x05"))
        XCTAssertTrue(rendered.contains("keybind = option+left=text:\\x1bb"))
        XCTAssertTrue(rendered.contains("keybind = option+right=text:\\x1bf"))
        XCTAssertTrue(rendered.contains("keybind = cmd+backspace=text:\\x15"))
        XCTAssertTrue(rendered.contains("keybind = option+backspace=text:\\x17"))
    }

    func testMergedUserConfigPrependsFallbackEditingBindings() {
        let rendered = GhosttyEmbeddedConfig
            .mergedUserConfigContents("font-size = 13\nkeybind = cmd+left=text:\\x02")

        XCTAssertTrue(rendered.contains("keybind = cmd+left=text:\\x01"))
        XCTAssertTrue(rendered.contains("keybind = option+left=text:\\x1bb"))
        XCTAssertTrue(rendered.contains("font-size = 13"))
        XCTAssertTrue(rendered.contains("keybind = cmd+left=text:\\x02"))
    }

    func testResolvedControllerConfigUsesGeneratedMergedSourceForUserConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty/config",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "font-size = 14".write(to: legacy, atomically: true, encoding: .utf8)

        let resolved = GhosttyEmbeddedConfig.resolvedControllerConfig(homeDirectoryURL: root)

        XCTAssertTrue(resolved.prefersUserConfig)
        XCTAssertEqual(resolved.userConfigPath, legacy.path)
        guard case let .generated(contents) = resolved.configSource else {
            return XCTFail("expected generated config source")
        }
        XCTAssertTrue(contents.contains("keybind = cmd+left=text:\\x01"))
        XCTAssertTrue(contents.contains("font-size = 14"))
    }
}
