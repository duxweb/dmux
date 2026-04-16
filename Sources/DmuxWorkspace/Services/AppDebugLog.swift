import AppKit
import Foundation

final class AppDebugLog: @unchecked Sendable {
    static let shared = AppDebugLog()

    private enum LoggingProfile {
        case verbose
        case compact
    }

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "dmux.debug.log", qos: .utility)
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private lazy var loggingProfile: LoggingProfile = {
        if let override = ProcessInfo.processInfo.environment["DMUX_LOG_PROFILE"]?.lowercased() {
            if override == "verbose" || override == "debug" {
                return .verbose
            }
            if override == "compact" || override == "release" {
                return .compact
            }
        }

        if let defaultsOverride = UserDefaults.standard.object(forKey: "dmux.logProfile") as? String {
            let normalized = defaultsOverride.lowercased()
            if normalized == "verbose" || normalized == "debug" {
                return .verbose
            }
            if normalized == "compact" || normalized == "release" {
                return .compact
            }
        }

        if let infoOverride = Bundle.main.object(forInfoDictionaryKey: "DMUXLogProfile") as? String {
            let normalized = infoOverride.lowercased()
            if normalized == "verbose" || normalized == "debug" {
                return .verbose
            }
            if normalized == "compact" || normalized == "release" {
                return .compact
            }
        }

        #if DEBUG
        return .verbose
        #else
        return .compact
        #endif
    }()

    private init() {}

    func logsDirectoryURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupport.appendingPathComponent("dmux/logs", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    func logFileURL() -> URL {
        logsDirectoryURL().appendingPathComponent("dmux-debug.log", isDirectory: false)
    }

    func previousLogFileURL() -> URL {
        logsDirectoryURL().appendingPathComponent("dmux-debug.previous.log", isDirectory: false)
    }

    func performanceSummaryFileURL() -> URL {
        logsDirectoryURL().appendingPathComponent("performance-summary.json", isDirectory: false)
    }

    func log(_ category: String, _ message: String) {
        guard shouldLog(category: category, message: message) else {
            return
        }

        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"
        let fileURL = logFileURL()

        queue.async {
            let fileManager = FileManager.default
            Self.rotateIfNeeded(fileURL: fileURL, fileManager: fileManager)

            let data = Data(line.utf8)
            if fileManager.fileExists(atPath: fileURL.path) == false {
                fileManager.createFile(atPath: fileURL.path, contents: data)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return
            }
            defer {
                try? handle.close()
            }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    func reset() {
        let fileURL = logFileURL()
        let archivedURL = previousLogFileURL()
        let performanceSummaryURL = performanceSummaryFileURL()
        queue.sync {
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: archivedURL)
            try? fileManager.removeItem(at: performanceSummaryURL)
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    private func shouldLog(category: String, message: String) -> Bool {
        if loggingProfile == .compact {
            switch category {
            case "startup-ui", "runtime-hooks", "terminal-start", "terminal-ready", "terminal-env":
                return false
            default:
                break
            }
        }

        switch category {
        case "terminal-env":
            return false
        case "app":
            return message != "open debug log"
        case "codex-hook":
            return !message.hasPrefix("ingest files=")
                && !message.hasPrefix("skip file=")
        default:
            return true
        }
    }

    func openInSystemViewer() {
        let url = logFileURL()
        if fileManager.fileExists(atPath: url.path) == false {
            fileManager.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    private static func rotateIfNeeded(fileURL: URL, fileManager: FileManager) {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 1_500_000 else {
            return
        }

        let archivedURL = fileURL.deletingLastPathComponent().appendingPathComponent("dmux-debug.previous.log", isDirectory: false)
        try? fileManager.removeItem(at: archivedURL)
        try? fileManager.moveItem(at: fileURL, to: archivedURL)
    }
}
