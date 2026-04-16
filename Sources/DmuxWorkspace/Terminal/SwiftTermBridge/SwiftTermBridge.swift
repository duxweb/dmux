import AppKit
import Darwin
import SwiftTerm
import SwiftUI
#if canImport(MetalKit)
import MetalKit
#endif

extension Notification.Name {
    static let dmuxTerminalFocusDidChange = Notification.Name("dmux.terminalFocusDidChange")
    static let dmuxTerminalOutputDidChange = Notification.Name("dmux.terminalOutputDidChange")
}

private final class SwiftTermOutputEventEmitter: @unchecked Sendable {
    static let shared = SwiftTermOutputEventEmitter()

    private let lock = NSLock()
    private var lastPostedAtBySessionID: [UUID: TimeInterval] = [:]
    private let minimumInterval: TimeInterval = 0.35

    func noteOutput(sessionID: UUID) {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldPost: Bool

        lock.lock()
        let lastPostedAt = lastPostedAtBySessionID[sessionID] ?? 0
        shouldPost = now - lastPostedAt >= minimumInterval
        if shouldPost {
            lastPostedAtBySessionID[sessionID] = now
        }
        lock.unlock()

        guard shouldPost else {
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dmuxTerminalOutputDidChange, object: sessionID)
        }
    }

    func clear(sessionID: UUID) {
        lock.lock()
        lastPostedAtBySessionID[sessionID] = nil
        lock.unlock()
    }
}

private final class DmuxLocalProcessTerminalView: LocalProcessTerminalView {
    var sessionID: UUID?
    var onFirstOutput: (() -> Void)?
    var onOutputActivity: (() -> Void)?
    private var hasObservedOutput = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let sessionID, !slice.isEmpty {
            SwiftTermOutputEventEmitter.shared.noteOutput(sessionID: sessionID)
        }
        if !slice.isEmpty, hasObservedOutput == false {
            hasObservedOutput = true
            DispatchQueue.main.async { [weak self] in
                self?.onFirstOutput?()
            }
        }
        if !slice.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onOutputActivity?()
            }
        }
        super.dataReceived(slice: slice)
    }

    func resetOutputObservation() {
        hasObservedOutput = false
    }
}

private extension NSColor {
    var swiftTermColor: SwiftTerm.Color {
        let converted = usingColorSpace(.deviceRGB) ?? self
        return SwiftTerm.Color(
            red: UInt16(max(0, min(65535, Int(converted.redComponent * 65535.0)))),
            green: UInt16(max(0, min(65535, Int(converted.greenComponent * 65535.0)))),
            blue: UInt16(max(0, min(65535, Int(converted.blueComponent * 65535.0))))
        )
    }
}

@MainActor
struct SwiftTermTerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let environment: [(String, String)]
    let terminalBackgroundPreset: AppTerminalBackgroundPreset
    let useMetalRendering: Bool
    let gpuMode: AppTerminalGPUMode
    let isFocused: Bool
    let isVisible: Bool
    let prefersReducedMemoryMode: Bool
    let shouldFocus: Bool
    var onInteraction: (() -> Void)? = nil
    var onFocusConsumed: (() -> Void)? = nil
    var onStartupSucceeded: (() -> Void)? = nil
    var onStartupFailure: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: session.id)
    }

    func makeNSView(context: Context) -> SwiftTermTerminalContainerView {
        AppDebugLog.shared.log(
            "startup-ui",
            "terminal-host make session=\(session.id.uuidString) project=\(session.projectID.uuidString)"
        )
        let view = SwiftTermTerminalRegistry.shared.containerView(
            for: session,
            environment: environment,
            terminalBackgroundPreset: terminalBackgroundPreset,
            useMetalRendering: useMetalRendering,
            gpuMode: gpuMode,
            isFocused: isFocused,
            isVisible: isVisible,
            prefersReducedMemoryMode: prefersReducedMemoryMode,
            onInteraction: onInteraction,
            onStartupSucceeded: onStartupSucceeded,
            onStartupFailure: onStartupFailure
        )
        context.coordinator.containerView = view
        if shouldFocus {
            DispatchQueue.main.async {
                view.focusTerminal()
                onFocusConsumed?()
            }
        }
        return view
    }

    func updateNSView(_ nsView: SwiftTermTerminalContainerView, context: Context) {
        nsView.updateSession(
            session,
            environment: environment,
            terminalBackgroundPreset: terminalBackgroundPreset,
            useMetalRendering: useMetalRendering,
            gpuMode: gpuMode,
            isFocused: isFocused,
            isVisible: isVisible,
            prefersReducedMemoryMode: prefersReducedMemoryMode,
            onInteraction: onInteraction,
            onStartupSucceeded: onStartupSucceeded,
            onStartupFailure: onStartupFailure
        )
        if shouldFocus {
            DispatchQueue.main.async {
                nsView.focusTerminal()
                onFocusConsumed?()
            }
        }
    }

    final class Coordinator {
        let sessionID: UUID
        weak var containerView: SwiftTermTerminalContainerView?

        init(sessionID: UUID) {
            self.sessionID = sessionID
        }
    }
}

@MainActor
final class SwiftTermTerminalContainerView: NSView {
    private let terminalView: DmuxLocalProcessTerminalView
    private let loadingShieldView = NSView(frame: .zero)
    private var configuredSession: TerminalSession
    private var configuredEnvironment: [(String, String)]
    private var terminalBackgroundPreset: AppTerminalBackgroundPreset
    private var preferredMetalRenderingEnabled = true
    private var gpuMode: AppTerminalGPUMode = .balanced
    private var isFocusedTerminal = false
    private var isVisibleTerminal = true
    private var prefersReducedMemoryMode = false
#if canImport(MetalKit)
    private var lastAppliedMetalBufferingMode: MetalBufferingMode?
#endif
    private let processInstanceID = UUID().uuidString.lowercased()
    private let processDelegateProxy = SwiftTermProcessDelegateProxy()
    private var onInteraction: (() -> Void)?
    private var onStartupSucceeded: (() -> Void)?
    private var onStartupFailure: ((String) -> Void)?
    private var hasStartedProcess = false
    private var hasReceivedInitialOutput = false
    private var pendingFocusRequest = false
    private var lastSyncedTerminalSize: CGSize = .zero
    private var pendingStartWorkItem: DispatchWorkItem?
    private var startupWatchdogWorkItem: DispatchWorkItem?
    private var startupAliveWithoutOutputWorkItem: DispatchWorkItem?
    private var adaptiveMetalCooldownWorkItem: DispatchWorkItem?
    private var hasReportedStartupFailure = false
    private var acceleratedRenderingUnavailable = false
    private var adaptiveMetalBoostActive = false
    private var interactionEventMonitors: [Any] = []
    private let logger = AppDebugLog.shared
    private let debugAIFocus = ProcessInfo.processInfo.environment["DMUX_DEBUG_AI_FOCUS"] == "1"
    private let startupDelay: TimeInterval = 0.22
    private let startupWatchdogDelay: TimeInterval = 3.5
    private let startupAliveWithoutOutputGraceDelay: TimeInterval = 4.5
    private let memorySaverMetalIdleDelay: TimeInterval = 12
    private lazy var clickRecognizer: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleContainerClick))
        recognizer.buttonMask = 0x1
        return recognizer
    }()

    init(
        session: TerminalSession,
        environment: [(String, String)],
        onInteraction: (() -> Void)?,
        onStartupSucceeded: (() -> Void)?,
        onStartupFailure: ((String) -> Void)?
    ) {
        self.configuredSession = session
        self.configuredEnvironment = environment
        self.terminalBackgroundPreset = .obsidian
        self.terminalView = DmuxLocalProcessTerminalView(frame: .zero)
        self.onInteraction = onInteraction
        self.onStartupSucceeded = onStartupSucceeded
        self.onStartupFailure = onStartupFailure
        super.init(frame: .zero)
        logger.log(
            "startup-ui",
            "terminal-container init session=\(session.id.uuidString) project=\(session.projectID.uuidString) cwd=\(session.cwd)"
        )
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSession(
        _ session: TerminalSession,
        environment: [(String, String)],
        terminalBackgroundPreset: AppTerminalBackgroundPreset,
        useMetalRendering: Bool,
        gpuMode: AppTerminalGPUMode,
        isFocused: Bool,
        isVisible: Bool,
        prefersReducedMemoryMode: Bool,
        onInteraction: (() -> Void)?,
        onStartupSucceeded: (() -> Void)?,
        onStartupFailure: ((String) -> Void)?
    ) {
        configuredEnvironment = environment
        applyTheme(terminalBackgroundPreset)
        preferredMetalRenderingEnabled = useMetalRendering
        self.gpuMode = gpuMode
        isFocusedTerminal = isFocused
        isVisibleTerminal = isVisible
        self.prefersReducedMemoryMode = prefersReducedMemoryMode
        self.onInteraction = onInteraction
        self.onStartupSucceeded = onStartupSucceeded
        self.onStartupFailure = onStartupFailure
        configureAcceleratedRenderingIfPossible()
        syncTerminalSizeIfNeeded(reason: "session-update")
        guard configuredSession.id != session.id else {
            scheduleProcessStartIfPossible(reason: "update-same-session")
            return
        }
        pendingStartWorkItem?.cancel()
        pendingStartWorkItem = nil
        startupWatchdogWorkItem?.cancel()
        startupWatchdogWorkItem = nil
        startupAliveWithoutOutputWorkItem?.cancel()
        startupAliveWithoutOutputWorkItem = nil
        adaptiveMetalCooldownWorkItem?.cancel()
        adaptiveMetalCooldownWorkItem = nil
        SwiftTermOutputEventEmitter.shared.clear(sessionID: configuredSession.id)
        configuredSession = session
        terminalView.sessionID = session.id
        terminalView.resetOutputObservation()
        lastSyncedTerminalSize = .zero
        hasReceivedInitialOutput = false
        pendingFocusRequest = false
        hasReportedStartupFailure = false
        adaptiveMetalBoostActive = false
        updateLoadingShieldVisibility()
        terminalView.terminate()
        hasStartedProcess = false
        logger.log(
            "startup-ui",
            "terminal-container rebind session=\(session.id.uuidString) project=\(session.projectID.uuidString)"
        )
        scheduleProcessStartIfPossible(reason: "update-new-session")
    }

    func prepareForHostReuse() {
        if superview != nil {
            removeFromSuperviewWithoutNeedingDisplay()
        }
    }

    func focusTerminal() {
        guard hasReceivedInitialOutput else {
            pendingFocusRequest = true
            logger.log("terminal-focus", "defer session=\(configuredSession.id.uuidString) reason=waiting-for-output")
            return
        }
        guard window?.firstResponder !== terminalView else { return }
        window?.makeFirstResponder(terminalView)
        SwiftTermTerminalRegistry.shared.markFocused(sessionID: configuredSession.id)
    }

    var terminalShellPID: Int32? {
        let pid = terminalView.process.shellPid
        return pid > 0 ? pid : nil
    }

    var terminalProjectID: UUID {
        configuredSession.projectID
    }

    var terminalProcessInstanceID: String {
        processInstanceID
    }

    func terminateProcessTree() {
        let shellPID = terminalShellPID ?? terminalView.process.shellPid
        resetTransientTerminalModes()
        guard shellPID > 0 else {
            terminalView.terminate()
            return
        }

        // forkpty children are normally session/process-group leaders. Kill the whole
        // process group first so spawned AI CLIs do not survive app/session teardown.
        kill(-shellPID, SIGTERM)
        kill(shellPID, SIGTERM)
        terminalView.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            guard kill(shellPID, 0) == 0 else {
                return
            }
            kill(-shellPID, SIGKILL)
            kill(shellPID, SIGKILL)
        }
    }

    var isTerminalFocused: Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if responder === terminalView {
            return true
        }
        if let view = responder as? NSView, view.isDescendant(of: terminalView) {
            return true
        }

        var next: NSResponder? = responder.nextResponder
        while let current = next {
            if current === terminalView {
                return true
            }
            next = current.nextResponder
        }
        return false
    }

    private func setup() {
        wantsLayer = true
        applyTheme(.obsidian)
        logger.log(
            "startup-ui",
            "terminal-container setup session=\(configuredSession.id.uuidString)"
        )

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = processDelegateProxy
        terminalView.caretColor = .systemBlue
        terminalView.optionAsMetaKey = false
        terminalView.allowMouseReporting = false
        terminalView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminalView.syncSequenceSettleMs = 8
        terminalView.disableFullRedrawOnAnyChanges = true
        terminalView.onFirstOutput = { [weak self] in
            self?.handleInitialTerminalOutput()
        }
        terminalView.onOutputActivity = { [weak self] in
            self?.handleTerminalOutputActivity()
        }

        loadingShieldView.translatesAutoresizingMaskIntoConstraints = false
        loadingShieldView.wantsLayer = true

        processDelegateProxy.onProcessTerminated = { [weak self] exitCode in
            self?.handleProcessTermination(exitCode: exitCode)
        }

        if let scrollView = terminalView.enclosingScrollView {
            scrollView.drawsBackground = false
        }

        addSubview(terminalView)
        addSubview(loadingShieldView)
        addGestureRecognizer(clickRecognizer)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            loadingShieldView.leadingAnchor.constraint(equalTo: leadingAnchor),
            loadingShieldView.trailingAnchor.constraint(equalTo: trailingAnchor),
            loadingShieldView.topAnchor.constraint(equalTo: topAnchor),
            loadingShieldView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateLoadingShieldVisibility()
    }

    private func resetTransientTerminalModes() {
        terminalView.getTerminal().feed(text: "\u{1b}[<u")
    }

    private func applyTheme(_ preset: AppTerminalBackgroundPreset) {
        terminalBackgroundPreset = preset
        layer?.backgroundColor = preset.backgroundColor.cgColor
        terminalView.nativeBackgroundColor = preset.backgroundColor
        terminalView.nativeForegroundColor = preset.foregroundColor
        terminalView.getTerminal().backgroundColor = preset.backgroundColor.swiftTermColor
        terminalView.getTerminal().foregroundColor = preset.foregroundColor.swiftTermColor
        loadingShieldView.layer?.backgroundColor = preset.backgroundColor.cgColor
        needsDisplay = true
        terminalView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        terminalView.needsLayout = true
        if hasStartedProcess {
            syncTerminalSizeIfNeeded(reason: "layout")
        } else {
            scheduleProcessStartIfPossible(reason: "layout")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            pendingStartWorkItem?.cancel()
            pendingStartWorkItem = nil
            startupWatchdogWorkItem?.cancel()
            startupWatchdogWorkItem = nil
            startupAliveWithoutOutputWorkItem?.cancel()
            startupAliveWithoutOutputWorkItem = nil
            adaptiveMetalCooldownWorkItem?.cancel()
            adaptiveMetalCooldownWorkItem = nil
            removeInteractionEventMonitors()
            return
        }
        installInteractionEventMonitorsIfNeeded()
        configureAcceleratedRenderingIfPossible()
        scheduleProcessStartIfPossible(reason: "window-attached")
    }

    private func installInteractionEventMonitorsIfNeeded() {
        guard interactionEventMonitors.isEmpty else {
            return
        }
        let masks: [NSEvent.EventTypeMask] = [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel
        ]
        interactionEventMonitors = masks.compactMap { mask in
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handlePotentialInteractionEvent(event)
                return event
            }
        }
    }

    private func removeInteractionEventMonitors() {
        for monitor in interactionEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        interactionEventMonitors.removeAll()
    }

    private func handlePotentialInteractionEvent(_ event: NSEvent) {
        guard event.window === window else {
            return
        }
        switch event.type {
        case .keyDown:
            if ownsResponder(window?.firstResponder) {
                handleTerminalInteraction()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) {
                handleTerminalInteraction()
            }
        default:
            break
        }
    }

    private func configureAcceleratedRenderingIfPossible() {
#if canImport(MetalKit)
        guard window != nil else {
            return
        }

        let desiredBufferingMode: MetalBufferingMode
        switch gpuMode {
        case .highPerformance:
            desiredBufferingMode = .perRowPersistent
        case .balanced:
            desiredBufferingMode = .perFrameAggregated
        case .memorySaver:
            desiredBufferingMode = .perFrameAggregated
        }
        if lastAppliedMetalBufferingMode != desiredBufferingMode {
            terminalView.metalBufferingMode = desiredBufferingMode
            lastAppliedMetalBufferingMode = desiredBufferingMode
            logger.log(
                "terminal-renderer",
                "session=\(configuredSession.id.uuidString) mode=\(gpuMode.rawValue) buffering=\(desiredBufferingMode == .perFrameAggregated ? "per-frame-aggregated" : "per-row-persistent") focused=\(isFocusedTerminal) visible=\(isVisibleTerminal) reducedMemory=\(prefersReducedMemoryMode)"
            )
        }

        let shouldUseMetal: Bool
        if preferredMetalRenderingEnabled == false {
            shouldUseMetal = false
        } else {
            switch gpuMode {
            case .highPerformance, .balanced:
                shouldUseMetal = true
            case .memorySaver:
                let eligibleForTemporaryBoost = isVisibleTerminal && isFocusedTerminal && !prefersReducedMemoryMode
                if eligibleForTemporaryBoost == false, adaptiveMetalBoostActive {
                    adaptiveMetalBoostActive = false
                    adaptiveMetalCooldownWorkItem?.cancel()
                    adaptiveMetalCooldownWorkItem = nil
                }
                shouldUseMetal = eligibleForTemporaryBoost && adaptiveMetalBoostActive
            }
        }

        if shouldUseMetal {
            guard terminalView.isUsingMetalRenderer == false else {
                return
            }
            guard acceleratedRenderingUnavailable == false else {
                return
            }
            do {
                try terminalView.setUseMetal(true)
                logger.log(
                    "terminal-renderer",
                    "session=\(configuredSession.id.uuidString) renderer=metal buffering=\(String(describing: terminalView.metalBufferingMode))"
                )
            } catch {
                acceleratedRenderingUnavailable = true
                logger.log(
                    "terminal-renderer",
                    "session=\(configuredSession.id.uuidString) renderer=coregraphics reason=\(error.localizedDescription)"
                )
            }
        } else {
            acceleratedRenderingUnavailable = false
            guard terminalView.isUsingMetalRenderer else {
                return
            }
            do {
                try terminalView.setUseMetal(false)
                logger.log(
                    "terminal-renderer",
                    "session=\(configuredSession.id.uuidString) renderer=coregraphics reason=disabled-by-settings"
                )
            } catch {
                logger.log(
                    "terminal-renderer",
                    "session=\(configuredSession.id.uuidString) renderer=metal-disable-failed reason=\(error.localizedDescription)"
                )
            }
        }
#endif
    }

    private func scheduleProcessStartIfPossible(reason: String) {
        guard hasStartedProcess == false else {
            return
        }
        guard pendingStartWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingStartWorkItem = nil
            self.startProcessIfPossible(trigger: reason)
        }
        pendingStartWorkItem = workItem
        logger.log(
            "terminal-start",
            "schedule session=\(configuredSession.id.uuidString) project=\(configuredSession.projectID.uuidString) reason=\(reason) delayMs=\(Int(startupDelay * 1000))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay, execute: workItem)
    }

    private func startProcessIfPossible(trigger: String) {
        guard hasStartedProcess == false else {
            return
        }
        guard window != nil,
              bounds.width > 0,
              bounds.height > 0,
              terminalView.bounds.width > 0,
              terminalView.bounds.height > 0 else {
            scheduleProcessStartIfPossible(reason: "\(trigger)-awaiting-layout")
            return
        }

        hasStartedProcess = true
        hasReportedStartupFailure = false
        forceTerminalResizeSync(reason: "pre-start")
        terminalView.sessionID = configuredSession.id
        let shell = configuredSession.shell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let launch = shellLaunchConfiguration(shell: shell, shellName: shellName, command: configuredSession.command)

        if debugAIFocus {
            print("[TerminalContainer] start sessionID=\(configuredSession.id.uuidString) shell=\(shell) command=\(configuredSession.command) size=\(Int(bounds.width))x\(Int(bounds.height)) termSize=\(Int(terminalView.bounds.width))x\(Int(terminalView.bounds.height))")
        }
        logger.log(
            "terminal-start",
            "begin session=\(configuredSession.id.uuidString) project=\(configuredSession.projectID.uuidString) reason=\(trigger) shell=\(shell) cwd=\(configuredSession.cwd) size=\(Int(bounds.width))x\(Int(bounds.height)) termSize=\(Int(terminalView.bounds.width))x\(Int(terminalView.bounds.height)) cols=\(terminalView.getTerminal().cols) rows=\(terminalView.getTerminal().rows)"
        )
        terminalView.startProcess(
            executable: shell,
            args: launch.args,
            environment: (configuredEnvironment + [("DMUX_SESSION_INSTANCE_ID", processInstanceID)]).map { "\($0.0)=\($0.1)" },
            execName: launch.execName,
            currentDirectory: configuredSession.cwd
        )
        installStartupWatchdog()
        DispatchQueue.main.async { [weak self] in
            self?.forceTerminalResizeSync(reason: "post-start")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.forceTerminalResizeSync(reason: "settle")
        }
        if debugAIFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                print("[TerminalContainer] sessionID=\(self.configuredSession.id.uuidString) shellPID=\(self.terminalShellPID.map(String.init) ?? "nil")")
            }
        }
    }

    private func forceTerminalResizeSync(reason: String) {
        layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        let size = terminalView.bounds.size
        guard size.width > 0, size.height > 0 else {
            return
        }
        lastSyncedTerminalSize = size
        terminalView.setFrameSize(size)
        if debugAIFocus {
            let cols = terminalView.getTerminal().cols
            let rows = terminalView.getTerminal().rows
            print("[TerminalContainer] resize-sync sessionID=\(configuredSession.id.uuidString) reason=\(reason) cols=\(cols) rows=\(rows) size=\(Int(size.width))x\(Int(size.height))")
        }
    }

    private func syncTerminalSizeIfNeeded(reason: String) {
        let size = terminalView.bounds.size
        guard size.width > 0, size.height > 0 else {
            return
        }
        guard abs(size.width - lastSyncedTerminalSize.width) > 0.5 || abs(size.height - lastSyncedTerminalSize.height) > 0.5 else {
            return
        }
        forceTerminalResizeSync(reason: reason)
    }

    private func handleInitialTerminalOutput() {
        guard hasReceivedInitialOutput == false else {
            return
        }
        hasReceivedInitialOutput = true
        startupWatchdogWorkItem?.cancel()
        startupWatchdogWorkItem = nil
        startupAliveWithoutOutputWorkItem?.cancel()
        startupAliveWithoutOutputWorkItem = nil
        hasReportedStartupFailure = false
        updateLoadingShieldVisibility()
        logger.log(
            "terminal-ready",
            "session=\(configuredSession.id.uuidString) project=\(configuredSession.projectID.uuidString) cols=\(terminalView.getTerminal().cols) rows=\(terminalView.getTerminal().rows)"
        )
        onStartupSucceeded?()
        if pendingFocusRequest {
            pendingFocusRequest = false
            focusTerminal()
        }
    }

    private func handleTerminalOutputActivity() {
        guard gpuMode == .memorySaver else {
            return
        }
        guard adaptiveMetalBoostActive else {
            return
        }
        scheduleAdaptiveMetalCooldown(reason: "output")
    }

    private func handleTerminalInteraction() {
        notifyInteraction()
        guard gpuMode == .memorySaver else {
            return
        }
        let eligibleForTemporaryBoost = preferredMetalRenderingEnabled && isVisibleTerminal && isFocusedTerminal && !prefersReducedMemoryMode
        guard eligibleForTemporaryBoost else {
            return
        }
        activateAdaptiveMetalBoost(reason: "interaction")
    }

    private func activateAdaptiveMetalBoost(reason: String) {
        let wasActive = adaptiveMetalBoostActive
        adaptiveMetalBoostActive = true
        scheduleAdaptiveMetalCooldown(reason: reason)
        if wasActive == false {
            logger.log(
                "terminal-renderer",
                "session=\(configuredSession.id.uuidString) renderer=metal-boost reason=\(reason) idleDelayMs=\(Int(memorySaverMetalIdleDelay * 1000))"
            )
        }
        configureAcceleratedRenderingIfPossible()
    }

    private func scheduleAdaptiveMetalCooldown(reason: String) {
        adaptiveMetalCooldownWorkItem?.cancel()
        guard gpuMode == .memorySaver, adaptiveMetalBoostActive else {
            adaptiveMetalCooldownWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.adaptiveMetalCooldownWorkItem = nil
            guard self.gpuMode == .memorySaver, self.adaptiveMetalBoostActive else {
                return
            }
            self.adaptiveMetalBoostActive = false
            self.logger.log(
                "terminal-renderer",
                "session=\(self.configuredSession.id.uuidString) renderer=metal-idle-expired reason=\(reason)"
            )
            self.configureAcceleratedRenderingIfPossible()
        }
        adaptiveMetalCooldownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + memorySaverMetalIdleDelay, execute: workItem)
    }

    private func handleProcessTermination(exitCode: Int32?) {
        resetTransientTerminalModes()
        startupWatchdogWorkItem?.cancel()
        startupWatchdogWorkItem = nil
        startupAliveWithoutOutputWorkItem?.cancel()
        startupAliveWithoutOutputWorkItem = nil
        adaptiveMetalCooldownWorkItem?.cancel()
        adaptiveMetalCooldownWorkItem = nil
        adaptiveMetalBoostActive = false
        if hasReceivedInitialOutput == false {
            hasReceivedInitialOutput = true
            updateLoadingShieldVisibility()
            reportStartupFailureIfNeeded(
                "process exited before terminal became ready (exit=\(exitCode.map(String.init) ?? "nil"))"
            )
        }
        pendingFocusRequest = false
        logger.log(
            "terminal-exit",
            "session=\(configuredSession.id.uuidString) project=\(configuredSession.projectID.uuidString) exit=\(exitCode.map(String.init) ?? "nil")"
        )
    }

    private func installStartupWatchdog() {
        startupWatchdogWorkItem?.cancel()
        startupAliveWithoutOutputWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.startupWatchdogWorkItem = nil
            guard self.hasReceivedInitialOutput == false else {
                return
            }
            guard self.terminalShellPID == nil else {
                self.logger.log(
                    "terminal-start",
                    "watchdog session=\(self.configuredSession.id.uuidString) shellPID=\(self.terminalShellPID.map(String.init) ?? "nil") result=alive-without-output"
                )
                self.installAliveWithoutOutputWatchdog()
                return
            }
            self.reportStartupFailureIfNeeded("shell pid not available after \(Int(self.startupWatchdogDelay * 1000))ms")
        }
        startupWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startupWatchdogDelay, execute: workItem)
    }

    private func installAliveWithoutOutputWatchdog() {
        startupAliveWithoutOutputWorkItem?.cancel()
        let totalDelayMs = Int((startupWatchdogDelay + startupAliveWithoutOutputGraceDelay) * 1000)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.startupAliveWithoutOutputWorkItem = nil
            guard self.hasReceivedInitialOutput == false else {
                return
            }
            self.reportStartupFailureIfNeeded("shell alive without output after \(totalDelayMs)ms")
        }
        startupAliveWithoutOutputWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startupAliveWithoutOutputGraceDelay, execute: workItem)
    }

    private func reportStartupFailureIfNeeded(_ detail: String) {
        guard hasReportedStartupFailure == false else {
            return
        }
        hasReportedStartupFailure = true
        logger.log(
            "terminal-recovery",
            "container-failed session=\(configuredSession.id.uuidString) project=\(configuredSession.projectID.uuidString) detail=\(detail)"
        )
        onStartupFailure?(detail)
    }

    private func updateLoadingShieldVisibility() {
        loadingShieldView.isHidden = hasReceivedInitialOutput
    }

    private func shellLaunchConfiguration(shell: String, shellName: String, command: String) -> (args: [String], execName: String) {
        guard command != shell else {
            switch shellName {
            case "zsh", "bash", "fish":
                // Match Terminal-style login shells so user profile/env initialization runs before dmux hooks.
                return (["-i", "-l"], shellName)
            default:
                return ([], shellName)
            }
        }

        switch shellName {
        case "zsh", "bash", "fish":
            return (["-i", "-l", "-c", command], shellName)
        default:
            return (["-lc", command], "-\(shellName)")
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: String(localized: "common.copy", defaultValue: "Copy", bundle: .module), action: #selector(copySelection), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = terminalView.selectionActive
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: String(localized: "common.paste", defaultValue: "Paste", bundle: .module), action: #selector(pasteClipboard), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: String(localized: "common.clear_screen", defaultValue: "Clear Screen", bundle: .module), action: #selector(clearScreen), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let selectAllItem = NSMenuItem(title: String(localized: "common.select_all", defaultValue: "Select All", bundle: .module), action: #selector(selectAllText), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }

    @objc
    private func copySelection() {
        terminalView.copy(self)
    }

    @objc
    private func pasteClipboard() {
        terminalView.paste(self)
    }

    @objc
    private func selectAllText() {
        terminalView.selectAll(self)
    }

    @objc
    private func clearScreen() {
        let bytes = Array("clear\n".utf8)
        terminalView.send(source: terminalView, data: bytes[...])
    }

    func sendText(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else {
            return
        }
        handleTerminalInteraction()
        terminalView.send(source: terminalView, data: bytes[...])
    }

    func sendInterrupt() {
        let interrupt: [UInt8] = [3]
        handleTerminalInteraction()
        terminalView.send(source: terminalView, data: interrupt[...])
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else {
            return false
        }
        if responder === terminalView {
            return true
        }
        if let view = responder as? NSView, view.isDescendant(of: terminalView) {
            return true
        }

        var next: NSResponder? = responder.nextResponder
        while let current = next {
            if current === terminalView {
                return true
            }
            next = current.nextResponder
        }
        return false
    }

    private func notifyInteraction() {
        onInteraction?()
    }

    @objc
    private func handleContainerClick() {
        focusTerminal()
        handleTerminalInteraction()
    }
}

@MainActor
final class SwiftTermTerminalRegistry {
    static let shared = SwiftTermTerminalRegistry()

    private var containers: [UUID: SwiftTermTerminalContainerView] = [:]
    private var explicitFocusedSessionID: UUID?
    private let debugAIFocus = ProcessInfo.processInfo.environment["DMUX_DEBUG_AI_FOCUS"] == "1"

    func containerView(
        for session: TerminalSession,
        environment: [(String, String)],
        terminalBackgroundPreset: AppTerminalBackgroundPreset,
        useMetalRendering: Bool,
        gpuMode: AppTerminalGPUMode,
        isFocused: Bool,
        isVisible: Bool,
        prefersReducedMemoryMode: Bool,
        onInteraction: (() -> Void)?,
        onStartupSucceeded: (() -> Void)?,
        onStartupFailure: ((String) -> Void)?
    ) -> SwiftTermTerminalContainerView {
        if let existing = containers[session.id] {
            if debugAIFocus {
                print("[TerminalRegistry] reuse sessionID=\(session.id.uuidString) shellPID=\(existing.terminalShellPID.map(String.init) ?? "nil")")
            }
            existing.prepareForHostReuse()
            existing.updateSession(
                session,
                environment: environment,
                terminalBackgroundPreset: terminalBackgroundPreset,
                useMetalRendering: useMetalRendering,
                gpuMode: gpuMode,
                isFocused: isFocused,
                isVisible: isVisible,
                prefersReducedMemoryMode: prefersReducedMemoryMode,
                onInteraction: onInteraction,
                onStartupSucceeded: onStartupSucceeded,
                onStartupFailure: onStartupFailure
            )
            return existing
        }

        let created = SwiftTermTerminalContainerView(
            session: session,
            environment: environment,
            onInteraction: onInteraction,
            onStartupSucceeded: onStartupSucceeded,
            onStartupFailure: onStartupFailure
        )
        created.updateSession(
            session,
            environment: environment,
            terminalBackgroundPreset: terminalBackgroundPreset,
            useMetalRendering: useMetalRendering,
            gpuMode: gpuMode,
            isFocused: isFocused,
            isVisible: isVisible,
            prefersReducedMemoryMode: prefersReducedMemoryMode,
            onInteraction: onInteraction,
            onStartupSucceeded: onStartupSucceeded,
            onStartupFailure: onStartupFailure
        )
        containers[session.id] = created
        if debugAIFocus {
            print("[TerminalRegistry] create sessionID=\(session.id.uuidString) cwd=\(session.cwd)")
        }
        return created
    }

    func release(sessionID: UUID) {
        guard let container = containers.removeValue(forKey: sessionID) else { return }
        if debugAIFocus {
            print("[TerminalRegistry] release sessionID=\(sessionID.uuidString) shellPID=\(container.terminalShellPID.map(String.init) ?? "nil")")
        }
        container.terminateProcessTree()
        SwiftTermOutputEventEmitter.shared.clear(sessionID: sessionID)
        container.removeFromSuperviewWithoutNeedingDisplay()
        if explicitFocusedSessionID == sessionID {
            explicitFocusedSessionID = nil
            NotificationCenter.default.post(name: .dmuxTerminalFocusDidChange, object: sessionID)
        }
    }

    func terminateAll() {
        let sessionIDs = Array(containers.keys)
        for sessionID in sessionIDs {
            release(sessionID: sessionID)
        }
    }

    func shellPID(for sessionID: UUID) -> Int32? {
        containers[sessionID]?.terminalShellPID
    }

    func projectID(for sessionID: UUID) -> UUID? {
        containers[sessionID]?.terminalProjectID
    }

    func sessionInstanceID(for sessionID: UUID) -> String? {
        containers[sessionID]?.terminalProcessInstanceID
    }

    func sendText(_ text: String, to sessionID: UUID) -> Bool {
        guard let container = containers[sessionID] else {
            return false
        }
        container.sendText(text)
        return true
    }

    func sendInterrupt(to sessionID: UUID) -> Bool {
        guard let container = containers[sessionID] else {
            return false
        }
        container.sendInterrupt()
        return true
    }

    func focusedSessionID() -> UUID? {
        if let explicitFocusedSessionID,
           containers[explicitFocusedSessionID] != nil {
            return explicitFocusedSessionID
        }
        return containers.first(where: { $0.value.isTerminalFocused })?.key
    }

    func markFocused(sessionID: UUID) {
        guard containers[sessionID] != nil else {
            return
        }
        guard explicitFocusedSessionID != sessionID else {
            return
        }
        explicitFocusedSessionID = sessionID
        NotificationCenter.default.post(name: .dmuxTerminalFocusDidChange, object: sessionID)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        containers.values.contains { $0.ownsResponder(responder) }
    }

    func debugSnapshot() -> String {
        containers
            .map { sessionID, container in
                let shellPID = container.terminalShellPID.map(String.init) ?? "nil"
                let focused = container.isTerminalFocused ? "focused" : "blurred"
                return "\(sessionID.uuidString):\(shellPID):\(focused)"
            }
            .sorted()
            .joined(separator: ", ")
    }
}

final class SwiftTermProcessDelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    var onProcessTerminated: ((Int32?) -> Void)?

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        onProcessTerminated?(exitCode)
    }
}
