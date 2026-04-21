import Foundation

struct GeminiToolDriver: AIToolDriver {
    let id = "gemini"
    let aliases: Set<String> = ["gemini"]
    let isRealtimeTool = true

    func matches(tool: String) -> Bool {
        aliases.contains(tool)
    }

    func resolveHookEvent(
        _ event: AIHookEvent,
        currentSession: AISessionStore.TerminalSessionState?
    ) async -> AIHookEvent {
        guard canonicalTool(event.tool) == id else {
            return event
        }

        var resolvedEvent = event
        let fallbackTotalTokens = currentSession?.committedTotalTokens
        resolvedEvent.model = resolvedEvent.model ?? currentSession?.model

        guard let projectPath = normalizedSessionID(event.projectPath),
              let parsedState = parseGeminiSessionRuntimeState(
                  projectPath: projectPath,
                  startedAt: currentSession?.startedAt ?? event.updatedAt,
                  preferredSessionID: normalizedSessionID(event.aiSessionID ?? currentSession?.aiSessionID),
                  preferredSessionIsAuthoritative: normalizedSessionID(event.aiSessionID ?? currentSession?.aiSessionID) != nil
              ) else {
            if resolvedEvent.totalTokens == nil {
                resolvedEvent.totalTokens = fallbackTotalTokens
            }
            return resolvedEvent
        }

        resolvedEvent.aiSessionID = normalizedSessionID(resolvedEvent.aiSessionID) ?? parsedState.externalSessionID
        resolvedEvent.model = resolvedEvent.model ?? parsedState.model
        resolvedEvent.totalTokens = max(
            resolvedEvent.totalTokens ?? 0,
            fallbackTotalTokens ?? 0,
            parsedState.totalTokens
        )

        if resolvedEvent.metadata?.source == nil {
            var metadata = resolvedEvent.metadata ?? AIHookEventMetadata()
            metadata.source = parsedState.origin == .restored ? "resume" : "startup"
            resolvedEvent.metadata = metadata
        }

        return resolvedEvent
    }

    func sessionCapabilities(for session: AISessionSummary) -> AIToolSessionCapabilities {
        let canOpen = !(session.externalSessionID?.isEmpty ?? true)
        return AIToolSessionCapabilities(canOpen: canOpen, canRename: false, canRemove: false)
    }

    func resumeCommand(for session: AISessionSummary) -> String? {
        guard let sessionID = session.externalSessionID, !sessionID.isEmpty else {
            return nil
        }
        return "gemini --resume \(shellQuoted(sessionID))"
    }

    private func canonicalTool(_ tool: String) -> String {
        aliases.contains(tool) ? id : tool
    }

    private func normalizedSessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

}
