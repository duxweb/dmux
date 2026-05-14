import Foundation

@MainActor
final class AIRuntimePollingService {
    static let shared = AIRuntimePollingService()

    private let aiSessionStore: AISessionStore
    private let toolDriverFactory: AIToolDriverFactory
    private let notificationCenter: NotificationCenter
    private let logger = AppDebugLog.shared
    private let interval: TimeInterval

    private var runtimeBridgeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var isPolling = false
    private var pendingPollReason: String?
    private var lastHookAppliedAtByTerminalID: [UUID: TimeInterval] = [:]
    private var transcriptMonitorTimer: Timer?
    private var transcriptMonitorsByTerminalID: [UUID: TranscriptMonitor] = [:]
    private let transcriptMonitorInterval: TimeInterval
    private let transcriptPollMinimumInterval: TimeInterval
    private let runningStateRenewalInterval: TimeInterval
    private let codexIntervalPollMinimumInterval: TimeInterval

    init(
        aiSessionStore: AISessionStore = .shared,
        toolDriverFactory: AIToolDriverFactory = .shared,
        notificationCenter: NotificationCenter = .default,
        interval: TimeInterval = 6,
        transcriptMonitorInterval: TimeInterval = 0.75,
        transcriptPollMinimumInterval: TimeInterval = 5,
        runningStateRenewalInterval: TimeInterval = 30,
        codexIntervalPollMinimumInterval: TimeInterval = 60
    ) {
        self.aiSessionStore = aiSessionStore
        self.toolDriverFactory = toolDriverFactory
        self.notificationCenter = notificationCenter
        self.interval = interval
        self.transcriptMonitorInterval = transcriptMonitorInterval
        self.transcriptPollMinimumInterval = transcriptPollMinimumInterval
        self.runningStateRenewalInterval = runningStateRenewalInterval
        self.codexIntervalPollMinimumInterval = codexIntervalPollMinimumInterval
    }

    func start() {
        guard runtimeBridgeObserver == nil else {
            sync(reason: "start-reuse")
            return
        }

        runtimeBridgeObserver = notificationCenter.addObserver(
            forName: .dmuxAIRuntimeBridgeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let kind = notification.userInfo?["kind"] as? String ?? "runtime-bridge"
            guard kind != "runtime-poll" else {
                return
            }
            Task { @MainActor [weak self] in
                self?.sync(reason: kind)
            }
        }

        sync(reason: "start")
    }

    func stop() {
        if let runtimeBridgeObserver {
            notificationCenter.removeObserver(runtimeBridgeObserver)
        }
        runtimeBridgeObserver = nil
        timer?.invalidate()
        timer = nil
        pendingPollReason = nil
        isPolling = false
        lastHookAppliedAtByTerminalID.removeAll()
        stopTranscriptMonitor()
    }

    func noteHookApplied(for terminalID: UUID, reason: String) {
        let now = Date().timeIntervalSince1970
        lastHookAppliedAtByTerminalID[terminalID] = now
        pruneHookMarkers(now: now)
        logger.log(
            "runtime-refresh",
            "hook terminal=\(terminalID.uuidString) reason=\(reason)"
        )
    }

    func sync(reason: String) {
        let trackedSessions = aiSessionStore.runtimeTrackedSessions()
        if trackedSessions.isEmpty {
            stopPolling(reason: reason)
            return
        }

        refreshTranscriptMonitors(for: trackedSessions)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePoll(reason: "interval")
                }
            }
            logger.log("runtime-refresh", "start interval=\(interval)s tracked=\(trackedSessions.count)")
        }

        schedulePoll(reason: reason)
    }

    private func schedulePoll(reason: String, terminalIDs: Set<UUID>? = nil) {
        if isPolling {
            pendingPollReason = reason
            return
        }

        let now = Date().timeIntervalSince1970
        pruneHookMarkers(now: now)
        let allRuntimeSessions = aiSessionStore.runtimeTrackedSessions()
        guard !allRuntimeSessions.isEmpty else {
            stopPolling(reason: reason)
            return
        }

        let runtimeSessions: [AISessionStore.TerminalSessionState]
        if let terminalIDs {
            runtimeSessions = allRuntimeSessions.filter { terminalIDs.contains($0.terminalID) }
        } else {
            runtimeSessions = allRuntimeSessions
        }

        guard !runtimeSessions.isEmpty else {
            return
        }

        let trackedSessions = runtimeSessions.filter { shouldPoll(session: $0, reason: reason, now: now) }
        guard !trackedSessions.isEmpty else {
            logger.log("runtime-refresh", "skip reason=\(reason) eligible=0")
            return
        }

        isPolling = true
        Task.detached(priority: .utility) { [toolDriverFactory, trackedSessions, startedAt = now] in
            var updates: [(UUID, AIRuntimeContextSnapshot)] = []
            for session in trackedSessions {
                guard let driver = toolDriverFactory.driver(for: session.tool),
                      let snapshot = await driver.runtimeSnapshot(for: session) else {
                    continue
                }
                updates.append((session.terminalID, snapshot))
            }
            await MainActor.run { [weak self] in
                self?.finishPoll(
                    updates: updates,
                    reason: reason,
                    startedAt: startedAt
                )
            }
        }
    }

    private func finishPoll(
        updates: [(UUID, AIRuntimeContextSnapshot)],
        reason: String,
        startedAt: TimeInterval
    ) {
        let now = Date().timeIntervalSince1970
        var didChange = false
        for (terminalID, snapshot) in updates {
            if shouldSkipSnapshot(terminalID: terminalID, pollStartedAt: startedAt, now: now) {
                logger.log(
                    "runtime-refresh",
                    "drop terminal=\(terminalID.uuidString) reason=\(reason) cause=recent-hook"
                )
                continue
            }
            var observedSnapshot = snapshot
            if shouldRenewRunningState(terminalID: terminalID, snapshot: observedSnapshot, now: now) {
                observedSnapshot.updatedAt = max(observedSnapshot.updatedAt, now)
            }
            didChange = aiSessionStore.applyRuntimeSnapshot(
                terminalID: terminalID,
                snapshot: observedSnapshot
            ) || didChange
        }

        if didChange {
            logger.log("runtime-refresh", "apply reason=\(reason) updates=\(updates.count)")
        }

        isPolling = false
        pruneHookMarkers(now: now)

        let trackedSessions = aiSessionStore.runtimeTrackedSessions()
        if trackedSessions.isEmpty {
            stopPolling(reason: reason)
        } else {
            refreshTranscriptMonitors(for: trackedSessions)
        }

        if didChange {
            notificationCenter.post(
                name: .dmuxAIRuntimeBridgeDidChange,
                object: nil,
                userInfo: ["kind": "runtime-poll"]
            )
        }

        if let pendingPollReason {
            self.pendingPollReason = nil
            schedulePoll(reason: pendingPollReason)
        }
    }

    private func shouldPoll(
        session: AISessionStore.TerminalSessionState,
        reason: String,
        now: TimeInterval
    ) -> Bool {
        if shouldUseTranscriptEventsOnly(session: session),
           reason == "interval",
           now - session.updatedAt < codexIntervalPollMinimumInterval {
            return false
        }

        switch session.state {
        case .responding, .needsInput:
            return true
        case .idle:
            return session.hasCompletedTurn == false
        }
    }

    private func shouldUseTranscriptEventsOnly(session: AISessionStore.TerminalSessionState) -> Bool {
        canonicalToolName(session.tool) == "codex"
            && normalizedNonEmptyString(session.transcriptPath) != nil
    }

    private func shouldSkipSnapshot(terminalID: UUID, pollStartedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard let lastHookAppliedAt = lastHookAppliedAtByTerminalID[terminalID] else {
            return false
        }
        _ = now
        return lastHookAppliedAt > pollStartedAt
    }

    private func shouldRenewRunningState(
        terminalID: UUID,
        snapshot: AIRuntimeContextSnapshot,
        now: TimeInterval
    ) -> Bool {
        guard snapshot.responseState == .responding,
              let session = aiSessionStore.session(for: terminalID) else {
            return false
        }
        return now - session.updatedAt >= runningStateRenewalInterval
    }

    private func pruneHookMarkers(now: TimeInterval) {
        lastHookAppliedAtByTerminalID = lastHookAppliedAtByTerminalID.filter { now - $0.value < max(interval * 2, 10) }
    }

    private func stopPolling(reason: String) {
        let hadActivePolling = timer != nil
            || transcriptMonitorTimer != nil
            || transcriptMonitorsByTerminalID.isEmpty == false

        timer?.invalidate()
        timer = nil
        pendingPollReason = nil
        stopTranscriptMonitor()

        if hadActivePolling {
            logger.log("runtime-refresh", "stop reason=\(reason) tracked=0")
        }
    }

    private func refreshTranscriptMonitors(for sessions: [AISessionStore.TerminalSessionState]) {
        let desiredSessions = sessions.filter { session in
            canonicalToolName(session.tool) == "codex" && normalizedNonEmptyString(session.transcriptPath) != nil
        }
        let desiredIDs = Set(desiredSessions.map(\.terminalID))

        for terminalID in Array(transcriptMonitorsByTerminalID.keys) where desiredIDs.contains(terminalID) == false {
            transcriptMonitorsByTerminalID.removeValue(forKey: terminalID)
        }

        for session in desiredSessions {
            guard let transcriptPath = normalizedNonEmptyString(session.transcriptPath) else {
                continue
            }
            if transcriptMonitorsByTerminalID[session.terminalID]?.path == transcriptPath {
                continue
            }
            transcriptMonitorsByTerminalID[session.terminalID] = TranscriptMonitor(
                path: transcriptPath,
                signature: transcriptSignature(path: transcriptPath),
                lastPollAt: nil
            )
            logger.log("runtime-refresh", "transcript-monitor start terminal=\(session.terminalID.uuidString) path=\(transcriptPath)")
        }

        if transcriptMonitorsByTerminalID.isEmpty {
            stopTranscriptMonitor()
        } else if transcriptMonitorTimer == nil {
            transcriptMonitorTimer = Timer.scheduledTimer(withTimeInterval: transcriptMonitorInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scanTranscriptMonitors()
                }
            }
            logger.log("runtime-refresh", "transcript-monitor timer interval=\(transcriptMonitorInterval)s")
        }
    }

    private func scanTranscriptMonitors() {
        guard !transcriptMonitorsByTerminalID.isEmpty else {
            stopTranscriptMonitor()
            return
        }

        let now = Date().timeIntervalSince1970
        var changedTerminalIDs = Set<UUID>()
        for (terminalID, monitor) in transcriptMonitorsByTerminalID {
            let signature = transcriptSignature(path: monitor.path)
            guard signature != monitor.signature else {
                continue
            }
            if let lastPollAt = monitor.lastPollAt,
               now - lastPollAt < transcriptPollMinimumInterval {
                continue
            }

            transcriptMonitorsByTerminalID[terminalID]?.signature = signature
            transcriptMonitorsByTerminalID[terminalID]?.lastPollAt = now
            changedTerminalIDs.insert(terminalID)
            logger.log("runtime-refresh", "transcript-monitor change terminal=\(terminalID.uuidString) path=\(monitor.path)")
        }

        if changedTerminalIDs.isEmpty == false {
            schedulePoll(reason: "transcript-tail", terminalIDs: changedTerminalIDs)
        }
    }

    private func stopTranscriptMonitor() {
        transcriptMonitorTimer?.invalidate()
        transcriptMonitorTimer = nil
        transcriptMonitorsByTerminalID.removeAll()
    }

    private func canonicalToolName(_ tool: String) -> String {
        switch tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude-code":
            return "claude"
        default:
            return tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private func transcriptSignature(path: String) -> TranscriptSignature? {
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return TranscriptSignature(
            size: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private struct TranscriptMonitor {
        var path: String
        var signature: TranscriptSignature?
        var lastPollAt: TimeInterval?
    }

    private struct TranscriptSignature: Equatable {
        var size: Int
        var modifiedAt: TimeInterval
    }

}
