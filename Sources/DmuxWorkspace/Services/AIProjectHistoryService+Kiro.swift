import Foundation

extension AIProjectHistoryService {
    func loadKiroFileSummaries(
        project: Project,
        indexingProfile: AIProjectHistoryIndexingProfile = .foreground
    ) async -> [AIExternalFileSummary] {
        let fileURLs = AIRuntimeSourceLocator.kiroSessionFileURLs(homeURL: runtimeHomeURL)
        logger.log(
            "history-refresh",
            "source=kiro locator=sessions-dir project=\(project.name) totalFiles=\(fileURLs.count)"
        )
        return await loadFileSummaries(
            source: "kiro",
            fileURLs: fileURLs,
            project: project,
            indexingProfile: indexingProfile,
            parser: parseKiroSessionFile
        )
    }

    func parseKiroSessionFile(fileURL: URL, project: Project) -> AIHistoryParseResult {
        var result = AIHistoryParseResult.empty
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = parseKiroSessionObject(object),
              pathsEquivalent(parsed.cwd, project.path) else {
            return .empty
        }

        let sessionID = parsed.sessionID.isEmpty
            ? fileURL.deletingPathExtension().lastPathComponent
            : parsed.sessionID
        let key = AIHistorySessionKey(source: "kiro", sessionID: sessionID)

        for turn in parsed.turns {
            guard let timestampString = turn["end_timestamp"] as? String,
                  let timestamp = parseAIHistoryISO8601Date(timestampString) else {
                continue
            }

            let roleString = (turn["result"] as? [String: Any])
                .flatMap { $0["Ok"] as? [String: Any] }
                .flatMap { $0["role"] as? String }
                ?? "assistant"
            let role: AIHistorySessionRole = roleString == "user" ? .user : .assistant

            result.events.append(
                AIHistorySessionEvent(
                    key: key,
                    projectName: project.name,
                    timestamp: timestamp,
                    role: role
                )
            )

            let model = parsed.modelName ?? "unknown"
            let inputTokens = jsonIntValue(turn["input_token_count"])
            let outputTokens = jsonIntValue(turn["output_token_count"])
            let total = inputTokens + outputTokens
            if total > 0 {
                result.entries.append(
                    AIHistoryUsageEntry(
                        key: key,
                        projectName: project.name,
                        timestamp: timestamp,
                        model: model,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cachedInputTokens: 0,
                        reasoningOutputTokens: 0
                    )
                )
            }
        }

        let sessionTitle = parsed.title ?? project.name
        result.metadataByKey[key] = AIHistorySessionMetadata(
            key: key,
            externalSessionID: sessionID,
            sessionTitle: sessionTitle,
            model: parsed.modelName
        )

        return result
    }
}
