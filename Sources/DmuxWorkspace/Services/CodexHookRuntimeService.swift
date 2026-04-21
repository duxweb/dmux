import Foundation

struct CodexParsedRuntimeState {
    var model: String?
    var totalTokens: Int?
    var updatedAt: Double?
    var startedAt: Double?
    var completedAt: Double?
    var responseState: AIResponseState?
    var wasInterrupted: Bool
    var hasCompletedTurn: Bool
}

func parseCodexRolloutRuntimeState(fileURL: URL?) -> CodexParsedRuntimeState? {
    parseCodexRuntimeState(fileURL: fileURL, projectPath: nil)
}

func parseCodexSessionRuntimeState(fileURL: URL?, projectPath: String) -> CodexParsedRuntimeState? {
    parseCodexRuntimeState(fileURL: fileURL, projectPath: projectPath)
}

func resolveCodexStopRuntimeState(transcriptPath: String?) async -> CodexParsedRuntimeState? {
    guard let transcriptPath else {
        return nil
    }

    let fileURL = URL(fileURLWithPath: transcriptPath)
    let retryDelays: [UInt64] = [0, 120_000_000, 280_000_000, 500_000_000, 900_000_000, 1_500_000_000]
    var latestState: CodexParsedRuntimeState?

    for delay in retryDelays {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        latestState = parseCodexRolloutRuntimeState(fileURL: fileURL)
        guard let latestState else {
            continue
        }
        if latestState.wasInterrupted || latestState.hasCompletedTurn || latestState.responseState == .idle {
            return latestState
        }
    }

    return latestState
}

private func parseCodexRuntimeState(fileURL: URL?, projectPath: String?) -> CodexParsedRuntimeState? {
    guard let fileURL,
          FileManager.default.fileExists(atPath: fileURL.path) else {
        return nil
    }

    let lines = tailJSONLinesFromFile(at: fileURL)
    guard !lines.isEmpty else {
        return nil
    }

    var latestModel: String?
    var latestUpdatedAt: Double?
    var latestStartedAt: Double?
    var latestCompletedAt: Double?
    var totalTokens: Int?
    var latestTurnWasInterrupted = false
    var latestTurnCompleted = false

    for line in lines {
        guard let data = line.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        let timestamp = (row["timestamp"] as? String).flatMap(parseCodexISO8601Date)?.timeIntervalSince1970
        if let timestamp {
            latestUpdatedAt = max(latestUpdatedAt ?? timestamp, timestamp)
        }

        let rowType = row["type"] as? String
        let payload = row["payload"] as? [String: Any] ?? [:]
        if rowType == "turn_context",
           let model = payload["model"] as? String,
           !model.isEmpty,
           projectPath == nil || (payload["cwd"] as? String) == projectPath {
            latestModel = model
            continue
        }

        let marksAssistantFinalAnswer: Bool = {
            if rowType == "event_msg",
               payload["type"] as? String == "agent_message",
               payload["phase"] as? String == "final_answer" {
                return true
            }
            if rowType == "response_item",
               payload["type"] as? String == "message",
               payload["phase"] as? String == "final_answer" {
                return true
            }
            return false
        }()

        if marksAssistantFinalAnswer {
            let completedAt = timestamp ?? latestUpdatedAt
            if let completedAt,
               latestCompletedAt == nil || completedAt >= (latestCompletedAt ?? 0) {
                latestCompletedAt = completedAt
                latestTurnWasInterrupted = false
                latestTurnCompleted = true
            }
            continue
        }

        guard rowType == "event_msg",
              let eventType = payload["type"] as? String else {
            continue
        }

        switch eventType {
        case "task_started":
            if let started = payload["started_at"] as? NSNumber {
                latestStartedAt = started.doubleValue
            } else if let timestamp {
                latestStartedAt = timestamp
            }
            latestTurnWasInterrupted = false
            latestTurnCompleted = false
        case "task_complete":
            let completedAt = (payload["completed_at"] as? NSNumber)?.doubleValue ?? timestamp
            if let completedAt,
               latestCompletedAt == nil || completedAt >= (latestCompletedAt ?? 0) {
                latestCompletedAt = completedAt
                latestTurnWasInterrupted = false
                latestTurnCompleted = true
            }
        case "turn_aborted":
            let completedAt = (payload["completed_at"] as? NSNumber)?.doubleValue ?? timestamp
            if let completedAt,
               latestCompletedAt == nil || completedAt >= (latestCompletedAt ?? 0) {
                latestCompletedAt = completedAt
                latestTurnWasInterrupted = true
                latestTurnCompleted = false
            }
        case "token_count":
            let info = payload["info"] as? [String: Any] ?? [:]
            let totalUsage = info["total_token_usage"] as? [String: Any] ?? [:]
            if let total = totalUsage["total_tokens"] as? NSNumber {
                totalTokens = total.intValue
            }
        default:
            continue
        }
    }

    let responseState: AIResponseState? = {
        guard let latestStartedAt else {
            return nil
        }
        if let latestCompletedAt, latestCompletedAt >= latestStartedAt {
            return .idle
        }
        return .responding
    }()

    return CodexParsedRuntimeState(
        model: latestModel,
        totalTokens: totalTokens,
        updatedAt: latestUpdatedAt,
        startedAt: latestStartedAt,
        completedAt: latestCompletedAt,
        responseState: responseState,
        wasInterrupted: latestTurnWasInterrupted,
        hasCompletedTurn: latestTurnCompleted
    )
}

private func tailJSONLinesFromFile(at fileURL: URL, maxBytes: Int = 262_144) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
        return []
    }
    defer {
        try? handle.close()
    }

    let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    let offset = max(0, fileSize - maxBytes)
    try? handle.seek(toOffset: UInt64(offset))
    let data = handle.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
        return []
    }

    let lines = text.split(separator: "\n").map(String.init)
    if offset == 0 {
        return lines
    }
    return Array(lines.dropFirst())
}
