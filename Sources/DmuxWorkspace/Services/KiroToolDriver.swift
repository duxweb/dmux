import Foundation

struct KiroParsedSession {
    let sessionID: String
    let cwd: String
    let title: String?
    let modelName: String?
    let turns: [[String: Any]]
}

func parseKiroSessionObject(_ object: [String: Any]) -> KiroParsedSession? {
    guard let cwd = normalizedNonEmptyString(object["cwd"] as? String) else { return nil }
    let sessionID = normalizedNonEmptyString(object["session_id"] as? String) ?? ""
    let title = normalizedNonEmptyString(object["title"] as? String)
    let sessionState = object["session_state"] as? [String: Any] ?? [:]
    let modelName = (sessionState["rts_model_state"] as? [String: Any])
        .flatMap { $0["model_info"] as? [String: Any] }
        .flatMap { normalizedNonEmptyString($0["model_name"] as? String) }
    let turns = (sessionState["conversation_metadata"] as? [String: Any])
        .flatMap { $0["user_turn_metadatas"] as? [[String: Any]] } ?? []
    return KiroParsedSession(sessionID: sessionID, cwd: cwd, title: title, modelName: modelName, turns: turns)
}

struct KiroToolDriver: AIToolDriver {
    let id = "kiro"
    let aliases: Set<String> = ["kiro", "kiro-cli"]
    let isRealtimeTool = true
    private let homeURL: URL?

    init(homeURL: URL? = nil) {
        self.homeURL = homeURL
    }

    func sessionCapabilities(for session: AISessionSummary) -> AIToolSessionCapabilities {
        AIToolSessionCapabilities(canOpen: true, canRename: false, canRemove: true)
    }

    func resumeCommand(for session: AISessionSummary) -> String? {
        guard let sessionID = session.externalSessionID, !sessionID.isEmpty else {
            return nil
        }
        return "kiro-cli --session \(shellQuoted(sessionID))"
    }

    func resolveHookEvent(
        _ event: AIHookEvent,
        currentSession: AISessionStore.TerminalSessionState?
    ) async -> AIHookEvent {
        guard canonicalToolName(event.tool) == id else {
            return event
        }
        var resolvedEvent = event
        let fallbackSession = matchingFallbackSession(for: event, currentSession: currentSession)
        resolvedEvent.model = resolvedEvent.model ?? fallbackSession?.model
        guard let projectPath = normalizedNonEmptyString(event.projectPath) else {
            if resolvedEvent.totalTokens == nil {
                resolvedEvent.totalTokens = fallbackSession?.committedTotalTokens
            }
            return resolvedEvent
        }
        guard let snapshot = resolvedKiroSessionSnapshot(
            projectPath: projectPath,
            externalSessionID: normalizedNonEmptyString(event.aiSessionID ?? fallbackSession?.aiSessionID)
        ) else {
            if resolvedEvent.totalTokens == nil {
                resolvedEvent.totalTokens = fallbackSession?.committedTotalTokens
            }
            return resolvedEvent
        }
        resolvedEvent.aiSessionID = normalizedNonEmptyString(resolvedEvent.aiSessionID) ?? snapshot.externalSessionID
        resolvedEvent.model = resolvedEvent.model ?? snapshot.model
        resolvedEvent.inputTokens = snapshot.inputTokens
        resolvedEvent.outputTokens = snapshot.outputTokens
        resolvedEvent.totalTokens = max(
            resolvedEvent.totalTokens ?? 0,
            fallbackSession?.committedTotalTokens ?? 0,
            snapshot.totalTokens
        )
        return resolvedEvent
    }

    func runtimeSnapshot(
        for session: AISessionStore.TerminalSessionState
    ) async -> AIRuntimeContextSnapshot? {
        guard let projectPath = normalizedNonEmptyString(session.projectPath) else {
            return nil
        }
        return resolvedKiroSessionSnapshot(
            projectPath: projectPath,
            externalSessionID: session.aiSessionID
        )
    }

    func resolvedKiroSessionSnapshot(
        projectPath: String,
        externalSessionID: String?
    ) -> AIRuntimeContextSnapshot? {
        let sessionURLs = AIRuntimeSourceLocator.kiroSessionFileURLs(homeURL: homeURL)
        guard !sessionURLs.isEmpty else { return nil }

        let candidates: [URL]
        if let sessionID = normalizedNonEmptyString(externalSessionID) {
            let specific = sessionURLs.filter {
                $0.deletingPathExtension().lastPathComponent == sessionID
            }
            candidates = specific.isEmpty ? sessionURLs : specific
        } else {
            candidates = sessionURLs
        }

        var bestSnapshot: AIRuntimeContextSnapshot?
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = parseKiroSessionObject(object),
                  pathsEquivalent(parsed.cwd, projectPath) else {
                continue
            }
            let sessionID = parsed.sessionID.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : parsed.sessionID

            var inputTokens = 0
            var outputTokens = 0
            var updatedAt = 0.0
            for turn in parsed.turns {
                inputTokens += jsonIntValue(turn["input_token_count"])
                outputTokens += jsonIntValue(turn["output_token_count"])
                if let ts = turn["end_timestamp"] as? String,
                   let date = parseAIHistoryISO8601Date(ts) {
                    updatedAt = max(updatedAt, date.timeIntervalSince1970)
                }
            }
            if updatedAt == 0 {
                updatedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate)
                    .map(\.timeIntervalSince1970) ?? Date().timeIntervalSince1970
            }
            let snapshot = AIRuntimeContextSnapshot(
                tool: "kiro",
                externalSessionID: sessionID,
                model: parsed.modelName,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: inputTokens + outputTokens,
                updatedAt: updatedAt,
                source: .probe
            )
            if bestSnapshot == nil || updatedAt > (bestSnapshot?.updatedAt ?? 0) {
                bestSnapshot = snapshot
            }
        }
        return bestSnapshot
    }

    func removeSession(_ session: AISessionSummary) throws {
        let targetSessionID = session.externalSessionID ?? session.sessionID.uuidString
        let fileManager = FileManager.default

        let candidates = AIRuntimeSourceLocator.kiroSessionFileURLs(homeURL: homeURL)
            .filter { $0.deletingPathExtension().lastPathComponent == targetSessionID
                || $0.lastPathComponent.contains(targetSessionID) }

        guard !candidates.isEmpty else {
            throw AIToolSessionControlError.sessionNotFound
        }
        for url in candidates {
            try fileManager.removeItem(at: url)
        }
    }
}
