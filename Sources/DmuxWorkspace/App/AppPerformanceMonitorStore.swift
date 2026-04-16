import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class AppPerformanceMonitorStore {
    struct ContextSnapshot {
        var projectName: String?
        var panelName: String
        var selectedSessionID: String?
        var activity: String

        static let empty = ContextSnapshot(
            projectName: nil,
            panelName: "none",
            selectedSessionID: nil,
            activity: "idle"
        )
    }

    struct Snapshot: Equatable {
        var timestamp: TimeInterval
        var cpuPercent: Double
        var memoryBytes: UInt64
        var graphicsBytes: UInt64
    }

    struct EventSummary: Codable {
        var type: String
        var occurredAt: TimeInterval
        var occurredAtISO8601: String
        var cpuPercent: Double?
        var cpuDisplay: String?
        var memoryBytes: UInt64?
        var memoryDisplay: String?
        var graphicsBytes: UInt64?
        var graphicsDisplay: String?
        var detail: String
        var project: String?
        var panel: String
        var session: String?
        var activity: String
        var appActive: Bool
    }

    struct SummaryPayload: Codable {
        var formatVersion: Int
        var sessionStartedAt: TimeInterval
        var sessionStartedAtISO8601: String
        var generatedAt: TimeInterval
        var generatedAtISO8601: String
        var sampleInterval: TimeInterval
        var inactiveSampleInterval: TimeInterval
        var events: [EventSummary]
    }

    private struct RawSample {
        var timestamp: TimeInterval
        var totalCPUTime: TimeInterval
        var memoryBytes: UInt64
        var graphicsBytes: UInt64
    }

    var isEnabled = false
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var graphicsBytes: UInt64 = 0
    var renderVersion: UInt64 = 0

    private let logger = AppDebugLog.shared
    private let summaryEventLimit = 24
    private let hangDetectionInterval: TimeInterval = 0.5
    private let hangDetectionThreshold: TimeInterval = 0.45
    private var sampleTimer: Timer?
    private var heartbeatTimer: Timer?
    private var previousRawSample: RawSample?
    private var lastLoggedSnapshot: Snapshot?
    private var lastSpikeLogAt: TimeInterval = 0
    private var lastHangLogAt: TimeInterval = 0
    private var expectedHeartbeatAt: TimeInterval?
    private var sampleInterval: TimeInterval = 3
    private var isApplicationActive = true
    private var contextProvider: @MainActor () -> ContextSnapshot = { .empty }
    private var recentEvents: [EventSummary] = []
    private let sessionStartedAt = Date().timeIntervalSince1970

    var inactiveSampleInterval: TimeInterval {
        max(sampleInterval * 3, 10)
    }

    func configure(isEnabled: Bool, sampleInterval: TimeInterval) {
        let normalizedInterval = max(1, sampleInterval)
        guard self.isEnabled != isEnabled || self.sampleInterval != normalizedInterval else {
            return
        }

        self.isEnabled = isEnabled
        self.sampleInterval = normalizedInterval
        if isEnabled {
            logger.log("performance-monitor", "enabled interval=\(Int(normalizedInterval))s")
            start()
        } else {
            logger.log("performance-monitor", "disabled")
            stop()
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            return
        }
        isApplicationActive = isActive
        guard isEnabled else {
            return
        }
        logger.log(
            "performance-monitor",
            "activity changed active=\(isActive) interval=\(Int(currentSampleInterval))s"
        )
        restartSampleTimer()
    }

    func setContextProvider(_ provider: @escaping @MainActor () -> ContextSnapshot) {
        contextProvider = provider
    }

    private func start() {
        stop(resetState: false)
        previousRawSample = nil
        recentEvents.removeAll()
        restartSampleTimer()
        startHeartbeatMonitor()
        persistSummary()
        sampleNow()
    }

    private func stop(resetState: Bool = true) {
        sampleTimer?.invalidate()
        sampleTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        expectedHeartbeatAt = nil
        previousRawSample = nil
        lastLoggedSnapshot = nil
        lastSpikeLogAt = 0
        lastHangLogAt = 0

        guard resetState else {
            return
        }

        if cpuPercent != 0 || memoryBytes != 0 || graphicsBytes != 0 {
            cpuPercent = 0
            memoryBytes = 0
            graphicsBytes = 0
            renderVersion &+= 1
        }
    }

    private var currentSampleInterval: TimeInterval {
        isApplicationActive ? sampleInterval : inactiveSampleInterval
    }

    private func restartSampleTimer() {
        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: currentSampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleNow()
            }
        }
    }

    private func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        expectedHeartbeatAt = CFAbsoluteTimeGetCurrent() + hangDetectionInterval
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: hangDetectionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkMainThreadStall()
            }
        }
    }

    private func sampleNow() {
        guard let rawSample = Self.captureRawSample() else {
            return
        }
        apply(rawSample: rawSample)
    }

    private func apply(rawSample: RawSample) {
        let nextCPUPercent: Double
        if let previousRawSample {
            let cpuDelta = max(0, rawSample.totalCPUTime - previousRawSample.totalCPUTime)
            let wallDelta = max(0.001, rawSample.timestamp - previousRawSample.timestamp)
            nextCPUPercent = max(0, (cpuDelta / wallDelta) * 100)
        } else {
            nextCPUPercent = 0
        }

        previousRawSample = rawSample

        let roundedCPU = (nextCPUPercent * 10).rounded() / 10
        let didChange = abs(cpuPercent - roundedCPU) >= 0.1
            || memoryBytes != rawSample.memoryBytes
            || graphicsBytes != rawSample.graphicsBytes
        cpuPercent = roundedCPU
        memoryBytes = rawSample.memoryBytes
        graphicsBytes = rawSample.graphicsBytes
        if didChange {
            renderVersion &+= 1
        }

        maybeLogSpike(snapshot: Snapshot(
            timestamp: rawSample.timestamp,
            cpuPercent: roundedCPU,
            memoryBytes: rawSample.memoryBytes,
            graphicsBytes: rawSample.graphicsBytes
        ))
    }

    private func checkMainThreadStall() {
        let now = CFAbsoluteTimeGetCurrent()
        let expected = expectedHeartbeatAt ?? (now + hangDetectionInterval)
        let lateness = now - expected
        expectedHeartbeatAt = now + hangDetectionInterval

        guard isApplicationActive,
              lateness >= hangDetectionThreshold,
              now - lastHangLogAt >= 15 else {
            return
        }

        lastHangLogAt = now
        let context = contextProvider()
        let detail = "main-thread stall=\(String(format: "%.0fms", lateness * 1000))"
        logger.log(
            "performance-monitor",
            "\(detail) panel=\(context.panelName) project=\(context.projectName ?? "nil") session=\(context.selectedSessionID ?? "nil") activity=\(context.activity)"
        )
        appendSummaryEvent(
            EventSummary(
                type: "stall",
                occurredAt: now,
                occurredAtISO8601: Self.isoTimestamp(now),
                cpuPercent: cpuPercent,
                cpuDisplay: formattedCPU,
                memoryBytes: memoryBytes,
                memoryDisplay: formattedMemory,
                graphicsBytes: graphicsBytes,
                graphicsDisplay: formattedGraphics,
                detail: detail,
                project: context.projectName,
                panel: context.panelName,
                session: context.selectedSessionID,
                activity: context.activity,
                appActive: isApplicationActive
            )
        )
    }

    private func maybeLogSpike(snapshot: Snapshot) {
        let previous = lastLoggedSnapshot
        defer { lastLoggedSnapshot = snapshot }

        guard let previous else {
            return
        }

        let cpuDelta = snapshot.cpuPercent - previous.cpuPercent
        let memoryDelta = Int64(snapshot.memoryBytes) - Int64(previous.memoryBytes)
        let memoryDeltaMB = Double(memoryDelta) / 1_048_576
        let graphicsDelta = Int64(snapshot.graphicsBytes) - Int64(previous.graphicsBytes)
        let graphicsDeltaMB = Double(graphicsDelta) / 1_048_576
        let now = snapshot.timestamp

        let isSpike =
            snapshot.cpuPercent >= 80
            || abs(cpuDelta) >= 25
            || abs(memoryDeltaMB) >= 256
            || abs(graphicsDeltaMB) >= 128

        guard isSpike, now - lastSpikeLogAt >= 15 else {
            return
        }

        lastSpikeLogAt = now
        let context = contextProvider()
        let detail =
            "spike cpu=\(String(format: "%.1f", snapshot.cpuPercent))% mem=\(Self.shortMemoryString(bytes: snapshot.memoryBytes)) gfx=\(Self.shortMemoryString(bytes: snapshot.graphicsBytes)) delta_cpu=\(String(format: "%+.1f", cpuDelta)) delta_mem=\(String(format: "%+.0fMB", memoryDeltaMB)) delta_gfx=\(String(format: "%+.0fMB", graphicsDeltaMB))"
        logger.log(
            "performance-monitor",
            "\(detail) panel=\(context.panelName) project=\(context.projectName ?? "nil") session=\(context.selectedSessionID ?? "nil") activity=\(context.activity)"
        )
        appendSummaryEvent(
            EventSummary(
                type: "spike",
                occurredAt: now,
                occurredAtISO8601: Self.isoTimestamp(now),
                cpuPercent: snapshot.cpuPercent,
                cpuDisplay: Self.cpuDisplay(snapshot.cpuPercent),
                memoryBytes: snapshot.memoryBytes,
                memoryDisplay: Self.memoryDisplay(snapshot.memoryBytes),
                graphicsBytes: snapshot.graphicsBytes,
                graphicsDisplay: Self.graphicsDisplay(snapshot.graphicsBytes),
                detail: detail,
                project: context.projectName,
                panel: context.panelName,
                session: context.selectedSessionID,
                activity: context.activity,
                appActive: isApplicationActive
            )
        )
    }

    var formattedCPU: String {
        Self.cpuDisplay(cpuPercent)
    }

    var formattedMemory: String {
        Self.memoryDisplay(memoryBytes)
    }

    var formattedGraphics: String {
        Self.graphicsDisplay(graphicsBytes)
    }

    private static func cpuDisplay(_ percent: Double) -> String {
        String(
            localized: "performance.monitor.cpu_format",
            defaultValue: "CPU %@",
            bundle: .module
        ).replacingOccurrences(of: "%@", with: String(format: "%.0f%%", percent))
    }

    private static func memoryDisplay(_ bytes: UInt64) -> String {
        String(
            localized: "performance.monitor.memory_format",
            defaultValue: "MEM %@",
            bundle: .module
        ).replacingOccurrences(of: "%@", with: Self.shortMemoryString(bytes: bytes))
    }

    private static func graphicsDisplay(_ bytes: UInt64) -> String {
        String(
            localized: "performance.monitor.graphics_format",
            defaultValue: "GFX %@",
            bundle: .module
        ).replacingOccurrences(of: "%@", with: Self.shortMemoryString(bytes: bytes))
    }

    private static func shortMemoryString(bytes: UInt64) -> String {
        let gigabyte = 1_073_741_824.0
        let megabyte = 1_048_576.0
        let value = Double(bytes)
        if value >= gigabyte {
            return String(format: "%.2fG", value / gigabyte)
        }
        return String(format: "%.0fM", value / megabyte)
    }

    private static func captureRawSample() -> RawSample? {
        let now = CFAbsoluteTimeGetCurrent()

        var threadInfo = task_thread_times_info_data_t()
        var threadCount = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: threadInfo) / MemoryLayout<natural_t>.size
        )
        let threadResult = withUnsafeMutablePointer(to: &threadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    $0,
                    &threadCount
                )
            }
        }
        guard threadResult == KERN_SUCCESS else {
            return nil
        }

        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: vmInfo) / MemoryLayout<natural_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &vmCount
                )
            }
        }
        guard vmResult == KERN_SUCCESS else {
            return nil
        }

        let userTime = TimeInterval(threadInfo.user_time.seconds) + TimeInterval(threadInfo.user_time.microseconds) / 1_000_000
        let systemTime = TimeInterval(threadInfo.system_time.seconds) + TimeInterval(threadInfo.system_time.microseconds) / 1_000_000
        let totalCPUTime = userTime + systemTime
        let totalMemoryBytes = vmInfo.phys_footprint > 0 ? vmInfo.phys_footprint : vmInfo.resident_size
        let graphicsFootprint = max(0, vmInfo.ledger_tag_graphics_footprint)
        let graphicsBytes = UInt64(graphicsFootprint)
        let memoryBytes = totalMemoryBytes > graphicsBytes ? totalMemoryBytes - graphicsBytes : totalMemoryBytes

        return RawSample(
            timestamp: now,
            totalCPUTime: totalCPUTime,
            memoryBytes: memoryBytes,
            graphicsBytes: graphicsBytes
        )
    }

    private func appendSummaryEvent(_ event: EventSummary) {
        recentEvents.append(event)
        if recentEvents.count > summaryEventLimit {
            recentEvents.removeFirst(recentEvents.count - summaryEventLimit)
        }
        persistSummary()
    }

    private func persistSummary() {
        let generatedAt = Date().timeIntervalSince1970
        let payload = SummaryPayload(
            formatVersion: 2,
            sessionStartedAt: sessionStartedAt,
            sessionStartedAtISO8601: Self.isoTimestamp(sessionStartedAt),
            generatedAt: generatedAt,
            generatedAtISO8601: Self.isoTimestamp(generatedAt),
            sampleInterval: sampleInterval,
            inactiveSampleInterval: inactiveSampleInterval,
            events: recentEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return
        }
        try? data.write(to: logger.performanceSummaryFileURL(), options: .atomic)
    }

    private static func isoTimestamp(_ unixTimestamp: TimeInterval) -> String {
        summaryDateFormatter.string(from: Date(timeIntervalSince1970: unixTimestamp))
    }

    private static let summaryDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
