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
    private var totalNormalizedTokensProvider: (@MainActor () -> Int)?
    private var computedStatsProvider: (@MainActor () -> PetStats)?
    private var pendingRefreshTask: Task<Void, Never>?
    private var periodicRefreshTimer: Timer?

    init(petStore: PetStore) {
        self.petStore = petStore
    }

    func configure(
        totalNormalizedTokens: @escaping @MainActor () -> Int,
        computedStats: @escaping @MainActor () -> PetStats
    ) {
        totalNormalizedTokensProvider = totalNormalizedTokens
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
              let totalNormalizedTokensProvider,
              let computedStatsProvider else {
            return
        }

        let totalNormalizedTokens = max(0, totalNormalizedTokensProvider())
        let computedStats = petStore.shouldRefreshStats(now: now)
            ? computedStatsProvider()
            : nil

        petStore.refreshDerivedState(
            totalNormalizedTokens: totalNormalizedTokens,
            computedStats: computedStats,
            now: now
        )

        logger.log(
            "pet-refresh",
            "reason=\(reason.rawValue) total=\(totalNormalizedTokens) watermark=\(petStore.globalNormalizedTotalWatermark ?? 0) hatch=\(petStore.currentHatchTokens) xp=\(petStore.currentExperienceTokens)"
        )
    }
}
