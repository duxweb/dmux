import Foundation
import Observation

@MainActor
@Observable
final class AIRuntimeStateStore {
    static let shared = AIRuntimeStateStore()
    private let logger = AppDebugLog.shared
    private let toolDriverFactory = AIToolDriverFactory.shared

    struct SessionState: Equatable {
        var sessionID: UUID
        var sessionInstanceID: String?
        var projectID: UUID
        var projectName: String
        var sessionTitle: String
        var tool: String
        var externalSessionID: String?
        var model: String?
        var status: String
        var responseState: AIResponseState?
        var updatedAt: Double
        var startedAt: Double?
        var inputTokens: Int
        var outputTokens: Int
        var totalTokens: Int
        var contextWindow: Int?
        var contextUsedTokens: Int?
        var contextUsagePercent: Double?
        var interruptedAt: Double?
        var hasCompletedTurn: Bool
    }

    var renderVersion: UInt64 = 0

    private(set) var sessionsByID: [UUID: SessionState] = [:]

    func applyLiveEnvelope(_ envelope: AIToolUsageEnvelope) {
        guard let sessionID = UUID(uuidString: envelope.sessionId),
              let projectID = UUID(uuidString: envelope.projectId) else {
            return
        }

        let existing = sessionsByID[sessionID]
        let existingUpdatedAt = existing?.updatedAt ?? 0
        let isNewInstance = {
            guard let incoming = envelope.sessionInstanceId, !incoming.isEmpty else {
                return false
            }
            return existing?.sessionInstanceID != incoming
        }()
        let incomingResponseState: AIResponseState? = {
            if envelope.updatedAt < existingUpdatedAt,
               existing?.responseState == .responding,
               envelope.responseState != .responding {
                return existing?.responseState
            }
            if let interruptedAt = existing?.interruptedAt,
               envelope.responseState == .responding,
               envelope.updatedAt <= interruptedAt {
                return existing?.responseState ?? .idle
            }
            return envelope.responseState ?? (isNewInstance ? nil : existing?.responseState)
        }()
        let nextInterruptedAt: Double? = {
            guard isNewInstance == false else {
                return nil
            }
            guard let interruptedAt = existing?.interruptedAt else {
                return nil
            }
            if envelope.updatedAt > interruptedAt,
               envelope.responseState == .responding {
                return nil
            }
            return interruptedAt
        }()
        let next = SessionState(
            sessionID: sessionID,
            sessionInstanceID: envelope.sessionInstanceId ?? existing?.sessionInstanceID,
            projectID: projectID,
            projectName: envelope.projectName,
            sessionTitle: envelope.sessionTitle,
            tool: envelope.tool.isEmpty ? ((isNewInstance ? nil : existing?.tool) ?? "") : envelope.tool,
            externalSessionID: envelope.externalSessionID ?? (isNewInstance ? nil : existing?.externalSessionID),
            model: envelope.model ?? (isNewInstance ? nil : existing?.model),
            status: envelope.status,
            responseState: incomingResponseState,
            updatedAt: max(envelope.updatedAt, existing?.updatedAt ?? 0),
            startedAt: envelope.startedAt ?? existing?.startedAt,
            inputTokens: isNewInstance ? max(0, envelope.inputTokens ?? 0) : max(envelope.inputTokens ?? 0, existing?.inputTokens ?? 0),
            outputTokens: isNewInstance ? max(0, envelope.outputTokens ?? 0) : max(envelope.outputTokens ?? 0, existing?.outputTokens ?? 0),
            totalTokens: isNewInstance ? max(0, envelope.totalTokens ?? 0) : max(envelope.totalTokens ?? 0, existing?.totalTokens ?? 0),
            contextWindow: isNewInstance ? envelope.contextWindow : (envelope.contextWindow ?? existing?.contextWindow),
            contextUsedTokens: isNewInstance ? envelope.contextUsedTokens : (envelope.contextUsedTokens ?? existing?.contextUsedTokens),
            contextUsagePercent: isNewInstance ? envelope.contextUsagePercent : (envelope.contextUsagePercent ?? existing?.contextUsagePercent),
            interruptedAt: nextInterruptedAt,
            hasCompletedTurn: envelope.responseState == .responding ? false : (isNewInstance ? false : (existing?.hasCompletedTurn ?? false))
        )
        let didChange = sessionsByID[sessionID] != next
        apply(next, for: sessionID)
        if didChange {
            logger.log(
                "runtime-store",
                "live session=\(sessionID.uuidString) tool=\(next.tool) status=\(next.status) model=\(next.model ?? "nil") response=\(next.responseState?.rawValue ?? "nil") total=\(next.totalTokens) external=\(next.externalSessionID ?? "nil") instance=\(next.sessionInstanceID ?? "nil")"
            )
        }
    }

    func applyResponsePayload(_ payload: AIResponseStatePayload) {
        guard let sessionID = UUID(uuidString: payload.sessionId) else {
            return
        }
        guard var existing = sessionsByID[sessionID] else {
            return
        }
        if shouldIgnoreIncomingTool(existing: existing, incomingTool: payload.tool) {
            logger.log(
                "runtime-store",
                "ignore response session=\(sessionID.uuidString) existingTool=\(existing.tool) incomingTool=\(payload.tool) state=\(payload.responseState.rawValue)"
            )
            return
        }
        let nextTool = resolvedTool(currentTool: existing.tool, incomingTool: payload.tool)
        let isStaleResponseTransition =
            payload.updatedAt < existing.updatedAt
            && existing.responseState != nil
            && existing.responseState != payload.responseState
        if isStaleResponseTransition {
            logger.log(
                "runtime-store",
                "ignore stale response session=\(sessionID.uuidString) tool=\(nextTool) state=\(payload.responseState.rawValue) payloadAt=\(payload.updatedAt) existingAt=\(existing.updatedAt) existingState=\(existing.responseState?.rawValue ?? "nil")"
            )
            return
        }
        let nextResponseState: AIResponseState? = {
            if let interruptedAt = existing.interruptedAt,
               payload.responseState == .responding,
               payload.updatedAt <= interruptedAt {
                return existing.responseState ?? .idle
            }
            return payload.responseState
        }()
        let nextInterruptedAt: Double? = {
            guard let interruptedAt = existing.interruptedAt else {
                return nil
            }
            if payload.updatedAt > interruptedAt,
               payload.responseState == .responding {
                return nil
            }
            return interruptedAt
        }()
        let didChange = existing.tool != nextTool
            || existing.responseState != nextResponseState
            || existing.interruptedAt != nextInterruptedAt
        guard didChange else {
            return
        }
        existing.tool = nextTool
        existing.responseState = nextResponseState
        existing.updatedAt = max(existing.updatedAt, payload.updatedAt)
        existing.interruptedAt = nextInterruptedAt
        if payload.responseState == .responding {
            existing.hasCompletedTurn = false
        }
        apply(existing, for: sessionID)
        logger.log(
            "runtime-store",
            "response session=\(sessionID.uuidString) tool=\(existing.tool) state=\(existing.responseState?.rawValue ?? "nil") updatedAt=\(existing.updatedAt)"
        )
    }

    func applyRuntimeSnapshot(sessionID: UUID, snapshot: AIRuntimeContextSnapshot) {
        guard var existing = sessionsByID[sessionID] else {
            return
        }
        if shouldIgnoreIncomingTool(existing: existing, incomingTool: snapshot.tool) {
            logger.log(
                "runtime-store",
                "ignore snapshot session=\(sessionID.uuidString) existingTool=\(existing.tool) incomingTool=\(snapshot.tool) response=\(snapshot.responseState?.rawValue ?? "nil") total=\(snapshot.totalTokens)"
            )
            return
        }
        let prefersHookDrivenResponseState = toolDriverFactory.prefersHookDrivenResponseState(for: snapshot.tool)
        let shouldPreserveHookRespondingState = prefersHookDrivenResponseState
            && existing.responseState == .responding
            && snapshot.responseState == .idle
            && snapshot.wasInterrupted == false
            && snapshot.hasCompletedTurn == false
        existing.tool = resolvedTool(currentTool: existing.tool, incomingTool: snapshot.tool)
        existing.externalSessionID = snapshot.externalSessionID ?? existing.externalSessionID
        existing.model = snapshot.model ?? existing.model
        existing.inputTokens = snapshot.inputTokens
        existing.outputTokens = snapshot.outputTokens
        existing.totalTokens = snapshot.totalTokens
        existing.updatedAt = max(existing.updatedAt, snapshot.updatedAt)
        if snapshot.wasInterrupted {
            existing.interruptedAt = max(existing.interruptedAt ?? 0, snapshot.updatedAt)
        }
        if snapshot.hasCompletedTurn {
            existing.hasCompletedTurn = true
        }
        let canApplySnapshotResponseState = prefersHookDrivenResponseState == false
            || existing.responseState == nil
            || snapshot.responseState == .idle
        if canApplySnapshotResponseState {
            if shouldPreserveHookRespondingState {
                existing.responseState = .responding
            } else if let interruptedAt = existing.interruptedAt,
               snapshot.responseState == .responding,
               snapshot.updatedAt <= interruptedAt {
                existing.responseState = existing.responseState ?? .idle
            } else {
                existing.responseState = snapshot.responseState ?? existing.responseState
                if let interruptedAt = existing.interruptedAt,
                   snapshot.updatedAt > interruptedAt,
                   snapshot.responseState == .responding {
                    existing.interruptedAt = nil
                }
            }
        }
        if snapshot.responseState == .responding || snapshot.wasInterrupted {
            existing.hasCompletedTurn = false
        }
        let didChange = sessionsByID[sessionID] != existing
        apply(existing, for: sessionID)
        if didChange {
            logger.log(
                "runtime-store",
                "snapshot session=\(sessionID.uuidString) tool=\(existing.tool) model=\(existing.model ?? "nil") response=\(existing.responseState?.rawValue ?? "nil") total=\(existing.totalTokens) external=\(existing.externalSessionID ?? "nil")"
            )
        }
    }

    @discardableResult
    func markInterrupted(sessionID: UUID, updatedAt: Double = Date().timeIntervalSince1970) -> Bool {
        guard var existing = sessionsByID[sessionID],
              existing.responseState == .responding else {
            return false
        }

        existing.responseState = .idle
        existing.updatedAt = max(existing.updatedAt, updatedAt)
        existing.interruptedAt = max(existing.interruptedAt ?? 0, updatedAt)
        existing.hasCompletedTurn = false
        apply(existing, for: sessionID)
        logger.log(
            "runtime-store",
            "interrupt session=\(sessionID.uuidString) tool=\(existing.tool) state=\(existing.responseState?.rawValue ?? "nil") updatedAt=\(existing.updatedAt)"
        )
        return true
    }

    func clearSession(_ sessionID: UUID) {
        if sessionsByID.removeValue(forKey: sessionID) != nil {
            renderVersion &+= 1
            logger.log("runtime-store", "clear session=\(sessionID.uuidString)")
        }
    }

    func reset() {
        guard !sessionsByID.isEmpty else {
            return
        }
        sessionsByID.removeAll()
        renderVersion &+= 1
        logger.log("runtime-store", "reset all")
    }

    func prune(projectID: UUID, liveSessionIDs: Set<UUID>) {
        let stale = sessionsByID.values
            .filter { $0.projectID == projectID && !liveSessionIDs.contains($0.sessionID) }
            .map(\.sessionID)
        guard !stale.isEmpty else {
            return
        }
        for sessionID in stale {
            sessionsByID[sessionID] = nil
        }
        renderVersion &+= 1
        logger.log("runtime-store", "prune project=\(projectID.uuidString) removed=\(stale.count)")
    }

    func projectPhase(projectID: UUID) -> ProjectActivityPhase {
        let sessions = sessionsByID.values
            .filter { $0.projectID == projectID && $0.status == "running" }
            .sorted { $0.updatedAt > $1.updatedAt }

        if let responding = sessions.first(where: { $0.responseState == .responding }) {
            return .running(tool: responding.tool)
        }
        return .idle
    }

    func liveSnapshots(projectID: UUID) -> [AITerminalSessionSnapshot] {
        sessionsByID.values
            .filter { $0.projectID == projectID && $0.status == "running" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(snapshot(from:))
    }

    func currentSnapshot(projectID: UUID, selectedSessionID: UUID?) -> AITerminalSessionSnapshot? {
        let snapshots = liveSnapshots(projectID: projectID)
        if let selectedSessionID,
           let selected = snapshots.first(where: { $0.sessionID == selectedSessionID }) {
            return selected
        }
        return snapshots.first
    }

    func sessionTitle(for sessionID: UUID) -> String? {
        sessionsByID[sessionID]?.sessionTitle
    }

    func responseState(for sessionID: UUID) -> AIResponseState? {
        sessionsByID[sessionID]?.responseState
    }

    func tool(for sessionID: UUID) -> String? {
        sessionsByID[sessionID]?.tool
    }

    func debugSummary(projectID: UUID) -> String {
        let sessions = sessionsByID.values
            .filter { $0.projectID == projectID }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard !sessions.isEmpty else {
            return "none"
        }

        return sessions.map { session in
            let updatedAt = String(format: "%.3f", session.updatedAt)
            return "session=\(session.sessionID.uuidString) tool=\(session.tool) status=\(session.status) response=\(session.responseState?.rawValue ?? "nil") updatedAt=\(updatedAt)"
        }
        .joined(separator: " | ")
    }

    private func apply(_ state: SessionState, for sessionID: UUID) {
        if sessionsByID[sessionID] != state {
            sessionsByID[sessionID] = state
            renderVersion &+= 1
        }
    }

    private func snapshot(from state: SessionState) -> AITerminalSessionSnapshot {
        AITerminalSessionSnapshot(
            sessionID: state.sessionID,
            externalSessionID: state.externalSessionID,
            projectID: state.projectID,
            projectName: state.projectName,
            sessionTitle: state.sessionTitle,
            tool: state.tool,
            model: state.model,
            status: state.status,
            responseState: state.responseState,
            startedAt: state.startedAt.map { Date(timeIntervalSince1970: $0) },
            updatedAt: Date(timeIntervalSince1970: state.updatedAt),
            currentInputTokens: state.inputTokens,
            currentOutputTokens: state.outputTokens,
            currentTotalTokens: state.totalTokens,
            currentContextWindow: state.contextWindow,
            currentContextUsedTokens: state.contextUsedTokens,
            currentContextUsagePercent: state.contextUsagePercent,
            wasInterrupted: state.interruptedAt != nil && state.responseState != .responding,
            hasCompletedTurn: state.hasCompletedTurn && state.responseState != .responding
        )
    }

    private func shouldIgnoreIncomingTool(existing: SessionState, incomingTool: String) -> Bool {
        guard existing.status == "running" else {
            return false
        }
        let currentTool = canonicalToolName(existing.tool)
        let nextTool = canonicalToolName(incomingTool)
        guard !currentTool.isEmpty, !nextTool.isEmpty else {
            return false
        }
        return currentTool != nextTool
    }

    private func resolvedTool(currentTool: String, incomingTool: String) -> String {
        guard !incomingTool.isEmpty else {
            return currentTool
        }
        let currentCanonical = canonicalToolName(currentTool)
        let incomingCanonical = canonicalToolName(incomingTool)
        if currentCanonical.isEmpty || incomingCanonical.isEmpty || currentCanonical == incomingCanonical {
            return incomingTool
        }
        return currentTool
    }

    private func canonicalToolName(_ tool: String) -> String {
        toolDriverFactory.canonicalToolName(tool)
    }
}
