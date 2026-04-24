import Foundation

struct AIToolEnvironmentService {
    private static let fallbackExecutablePath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
    private static let allowedDotEnvKeys: Set<String> = [
        "GEMINI_API_KEY",
        "GEMINI_MODEL",
        "GOOGLE_API_KEY",
        "GOOGLE_GEMINI_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "CODEX_HOME",
        "OPENCODE_API_KEY",
        "OPENCODE_BASE_URL",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
    ]
    private static let loginShellPathCache = LoginShellPathCache()

    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func configuredEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        for url in dotenvURLs() {
            for (key, value) in loadDotEnv(at: url) where environment[key]?.isEmpty ?? true {
                environment[key] = value
            }
        }
        return environment
    }

    func mergedEnvironment(
        into base: [String: String] = ProcessInfo.processInfo.environment,
        includeBundledWrappers: Bool = true,
        includeGeminiPlaceholder: Bool = false
    ) -> [String: String] {
        var environment = base
        for (key, value) in configuredEnvironment() where environment[key]?.isEmpty ?? true {
            environment[key] = value
        }
        environment["PATH"] = mergedExecutablePath(environment["PATH"], includeBundledWrappers: includeBundledWrappers)
        if includeGeminiPlaceholder, environment["GEMINI_API_KEY"]?.isEmpty ?? true {
            environment["GEMINI_API_KEY"] = "codux-placeholder-key"
        }
        return environment
    }

    private func mergedExecutablePath(_ currentPath: String?, includeBundledWrappers: Bool) -> String {
        let bundledWrapperPath = WorkspacePaths.repositoryResourceURL("scripts/wrappers/bin").path
        let defaultPath = currentPath.flatMap(normalizedNonEmptyString) ?? Self.fallbackExecutablePath
        let userToolPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".cargo/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".opencode/bin", isDirectory: true).path,
        ]
        let excludedPaths = includeBundledWrappers ? Set<String>() : [bundledWrapperPath]
        let loginShellPaths = resolvedLoginShellPathComponents(excluding: excludedPaths)
        let extraPaths = includeBundledWrappers ? [bundledWrapperPath] + loginShellPaths + userToolPaths : loginShellPaths + userToolPaths
        var seen = Set<String>()
        return (extraPaths + defaultPath.components(separatedBy: ":"))
            .compactMap(normalizedNonEmptyString)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private func resolvedLoginShellPathComponents(excluding excludedPaths: Set<String>) -> [String] {
        guard let path = Self.loginShellPathCache.value(for: loginShellPathCacheKey(), loader: resolveLoginShellPath()) else {
            return []
        }
        return path
            .components(separatedBy: ":")
            .compactMap(normalizedNonEmptyString)
            .filter { !excludedPaths.contains($0) }
    }

    private func loginShellPathCacheKey() -> String {
        [
            preferredShellPath(),
            homeDirectory.path,
            ProcessInfo.processInfo.environment["USER"] ?? "",
        ].joined(separator: "|")
    }

    private func preferredShellPath() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/bash",
        ]
        for candidate in candidates {
            guard let path = normalizedNonEmptyString(candidate),
                  fileManager.isExecutableFile(atPath: path) else {
                continue
            }
            return path
        }
        return "/bin/zsh"
    }

    private func resolveLoginShellPath() -> String? {
        let shellPath = preferredShellPath()
        let beginMarker = "__DMUX_LOGIN_PATH_BEGIN__"
        let endMarker = "__DMUX_LOGIN_PATH_END__"
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = [
            "-lic",
            "printf '\(beginMarker)%s\(endMarker)' \"$PATH\"",
        ]
        process.environment = [
            "HOME": homeDirectory.path,
            "USER": ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            "LOGNAME": ProcessInfo.processInfo.environment["LOGNAME"] ?? NSUserName(),
            "PATH": Self.fallbackExecutablePath + ":/opt/homebrew/bin",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8),
              let beginRange = output.range(of: beginMarker),
              let endRange = output.range(of: endMarker, range: beginRange.upperBound..<output.endIndex) else {
            return nil
        }
        let path = String(output[beginRange.upperBound..<endRange.lowerBound])
        return normalizedNonEmptyString(path)
    }

    private func dotenvURLs() -> [URL] {
        [
            homeDirectory.appendingPathComponent(".gemini/.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".claude/.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".codex/.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".opencode/.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".config/opencode/.env", isDirectory: false),
        ]
    }

    private func loadDotEnv(at url: URL) -> [String: String] {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.allowedDotEnvKeys.contains(key) else {
                continue
            }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}

private final class LoginShellPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func value(for key: String, loader: @autoclosure () -> String?) -> String? {
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let resolved = loader() else {
            return nil
        }

        lock.lock()
        storage[key] = resolved
        lock.unlock()
        return resolved
    }
}
