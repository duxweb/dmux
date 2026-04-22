import Foundation

@MainActor
final class PetRefreshCoordinator {
    static let liveDebounceDelay: Duration = .seconds(2)

    enum Reason: String {
        case bootstrap = "bootstrap"
        case aiSession = "ai-session"
        case claim = "claim"
        case periodic = "periodic"
    }

    private let petStore: PetStore
    private let logger = AppDebugLog.shared
    private var allTimeTokensProvider: (@MainActor () -> Int)?
    private var computedStatsProvider: (@MainActor () -> PetStats)?
    private var pendingRefreshTask: Task<Void, Never>?
    private var periodicRefreshTimer: Timer?

    init(petStore: PetStore) {
        self.petStore = petStore
    }

    func configure(
        allTimeTokens: @escaping @MainActor () -> Int,
        computedStats: @escaping @MainActor () -> PetStats
    ) {
        allTimeTokensProvider = allTimeTokens
        computedStatsProvider = computedStats
    }

    func start() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow(reason: .periodic)
            }
        }
        refreshNow(reason: .bootstrap)
    }

    func stop() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
    }

    func scheduleRefresh(reason: Reason, delay: Duration = PetRefreshCoordinator.liveDebounceDelay) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else {
                return
            }
            self.pendingRefreshTask = nil
            self.refreshNow(reason: reason)
        }
    }

    func refreshNow(reason: Reason, now: Date = .init()) {
        guard petStore.isClaimed,
              let allTimeTokensProvider,
              let computedStatsProvider else {
            return
        }

        let currentAllTimeTokens = max(0, allTimeTokensProvider())
        let computedStats = petStore.shouldRefreshStats(now: now)
            ? computedStatsProvider()
            : petStore.currentStats

        petStore.refreshDerivedState(
            currentAllTimeTokens: currentAllTimeTokens,
            computedStats: computedStats,
            now: now
        )

        logger.log(
            "pet-refresh",
            "reason=\(reason.rawValue) claimed=\(petStore.currentHatchTokens) xp=\(petStore.currentExperienceTokens)"
        )
    }
}
