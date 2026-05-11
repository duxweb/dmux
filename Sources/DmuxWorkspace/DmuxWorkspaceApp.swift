import SwiftUI
import AppKit
import Observation
import UserNotifications

@MainActor
enum FileBrowserKeyboardFocusState {
    enum Context: Equatable {
        case none
        case terminal
        case fileBrowser
        case workspaceFileEditor(tabID: String?)
    }

    private(set) static var context: Context = .none
    static var isInlineRenaming = false

    static var isActive: Bool {
        get {
            context == .fileBrowser
        }
        set {
            if newValue {
                activateFileBrowser(isInlineRenaming: isInlineRenaming)
            } else {
                clearFileBrowserIfNeeded()
            }
        }
    }

    static var isWorkspaceFileEditorActive: Bool {
        if case .workspaceFileEditor = context {
            return true
        }
        return false
    }

    static var activeWorkspaceFileEditorTabID: String? {
        if case .workspaceFileEditor(let tabID) = context {
            return tabID
        }
        return nil
    }

    static var shouldSuppressTerminalRouting: Bool {
        switch context {
        case .fileBrowser:
            return isInlineRenaming == false
        case .workspaceFileEditor:
            return true
        case .none, .terminal:
            return false
        }
    }

    static func activateFileBrowser(isInlineRenaming: Bool) {
        context = .fileBrowser
        self.isInlineRenaming = isInlineRenaming
        DmuxTerminalBackend.shared.registry.clearFocusedSession()
    }

    static func activateWorkspaceFileEditor(tabID: String?) {
        context = .workspaceFileEditor(tabID: tabID)
        isInlineRenaming = false
        DmuxTerminalBackend.shared.registry.clearFocusedSession()
    }

    static func activateTerminal() {
        context = .terminal
        isInlineRenaming = false
    }

    static func clearWorkspaceFileEditor(tabID: String?) {
        guard case .workspaceFileEditor(let currentTabID) = context,
              currentTabID == tabID || tabID == nil else {
            return
        }
        context = .none
        isInlineRenaming = false
    }

    static func clearFileBrowserIfNeeded() {
        guard context == .fileBrowser else {
            return
        }
        context = .none
        isInlineRenaming = false
    }

    static func updateFileBrowserInlineRenaming(_ isInlineRenaming: Bool) {
        guard context == .fileBrowser else {
            return
        }
        self.isInlineRenaming = isInlineRenaming
    }

    static func shouldHandleFileBrowserShortcut(
        context: Context,
        isActive: Bool,
        isInlineRenaming: Bool,
        hasWindow: Bool,
        eventWindowMatches: Bool,
        isTerminalResponder: Bool
    ) -> Bool {
        context == .fileBrowser
            && isActive
            && isInlineRenaming == false
            && hasWindow
            && eventWindowMatches
            && isTerminalResponder == false
    }

    static func shouldHandleFileBrowserShortcut(
        isActive: Bool,
        isInlineRenaming: Bool,
        hasWindow: Bool,
        eventWindowMatches: Bool,
        isTerminalResponder: Bool
    ) -> Bool {
        shouldHandleFileBrowserShortcut(
            context: isActive ? .fileBrowser : .none,
            isActive: isActive,
            isInlineRenaming: isInlineRenaming,
            hasWindow: hasWindow,
            eventWindowMatches: eventWindowMatches,
            isTerminalResponder: isTerminalResponder
        )
    }
}

enum TerminalKeyRoutingPolicy {
    static func shouldRouteToTerminal(
        isMainMenuShortcut: Bool,
        isReservedApplicationShortcut: Bool,
        isWorkspaceEditorFocused: Bool = false
    ) -> Bool {
        !isMainMenuShortcut && !isReservedApplicationShortcut && !isWorkspaceEditorFocused
    }
}

enum WorkspaceKeyboardFocusScope: String {
    case workspace
    case workspaceReview
    case fileBrowser
    case fileEditor
    case workspaceFiles
    case terminal
}

enum WorkspaceKeyboardCommandAction: Equatable {
    case closeFileTab
    case saveFileTab
    case closeTerminalSplit
    case passThrough
}

enum WorkspaceKeyboardRouter {
    static func focusScope(
        focusContext: FileBrowserKeyboardFocusState.Context,
        isSelectedWorkspaceFilesModeActive: Bool,
        isSelectedWorkspaceReviewModeActive: Bool,
        isWorkspaceFileCommandActive: Bool,
        isTerminalResponder: Bool,
        isSystemTextResponder: Bool,
        responderClassName: String?
    ) -> WorkspaceKeyboardFocusScope {
        if focusContext == .fileBrowser, isSystemTextResponder == false {
            return .fileBrowser
        }
        if isSelectedWorkspaceReviewModeActive {
            return .workspaceReview
        }
        if isTerminalResponder {
            return .terminal
        }
        if isSourceEditorResponder(className: responderClassName) {
            return .fileEditor
        }
        if case .workspaceFileEditor = focusContext {
            return .fileEditor
        }
        if isWorkspaceFileCommandActive {
            return .fileEditor
        }
        if isSelectedWorkspaceFilesModeActive {
            return .workspaceFiles
        }
        return .workspace
    }

    static func commandAction(
        key: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        scope: WorkspaceKeyboardFocusScope
    ) -> WorkspaceKeyboardCommandAction {
        guard modifiers == [.command] else {
            return .passThrough
        }
        switch normalizedKey(key: key, keyCode: keyCode) {
        case "w":
            switch scope {
            case .fileBrowser, .fileEditor, .workspaceFiles:
                return .closeFileTab
            case .terminal:
                return .closeTerminalSplit
            case .workspace, .workspaceReview:
                return .passThrough
            }
        case "s":
            switch scope {
            case .fileEditor, .workspaceFiles:
                return .saveFileTab
            default:
                return .passThrough
            }
        default:
            return .passThrough
        }
    }

    static func shouldPreferFileBrowserShortcut(
        key: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        scope: WorkspaceKeyboardFocusScope
    ) -> Bool {
        guard scope == .fileBrowser else {
            return false
        }
        if modifiers == [.command] {
            switch normalizedKey(key: key, keyCode: keyCode) {
            case "c", "x", "v":
                return true
            default:
                return false
            }
        }
        return keyCode == 36 || keyCode == 76 || keyCode == 51 || keyCode == 117
    }

    static func normalizedKey(key: String?, keyCode: UInt16) -> String? {
        if let key, !key.isEmpty {
            return key.lowercased()
        }
        switch keyCode {
        case 0:
            return "a"
        case 1:
            return "s"
        case 8:
            return "c"
        case 9:
            return "v"
        case 7:
            return "x"
        case 13:
            return "w"
        default:
            return nil
        }
    }

    private static func isSourceEditorResponder(className: String?) -> Bool {
        guard let className else {
            return false
        }
        return className.contains("SourceEditorTextView")
            || className.contains("CodeEditTextView.TextView")
    }
}

enum AppWindowIdentifier {
    static let main = NSUserInterfaceItemIdentifier("dmux.main")
    static let settings = NSUserInterfaceItemIdentifier("dmux.settings")
    static let about = NSUserInterfaceItemIdentifier("dmux.about")
    static let agreement = NSUserInterfaceItemIdentifier("dmux.agreement")
    static let petDex = NSUserInterfaceItemIdentifier("dmux.petDex")
    static let desktopPet = NSUserInterfaceItemIdentifier("dmux.desktopPet")
    static let memoryManager = NSUserInterfaceItemIdentifier("dmux.memoryManager")
    static let gitDiff = NSUserInterfaceItemIdentifier("dmux.gitDiff")
    static let detachedTerminalPrefix = "dmux.detached-terminal."

    static func detachedTerminal(_ sessionID: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("\(detachedTerminalPrefix)\(sessionID.uuidString)")
    }
}

@MainActor
func applyStandardWindowChrome(
    _ window: NSWindow,
    title: String? = nil,
    toolbarStyle: NSWindow.ToolbarStyle = .automatic,
    backgroundColor: NSColor = .windowBackgroundColor
) {
    if let title {
        window.title = title
    }
    window.styleMask.remove(.fullSizeContentView)
    window.titleVisibility = .visible
    window.titlebarAppearsTransparent = false
    window.isMovableByWindowBackground = false
    window.backgroundColor = backgroundColor
    if toolbarStyle != .preference {
        window.toolbar = nil
    }
    if #available(macOS 13.0, *) {
        window.toolbarStyle = toolbarStyle
    }
}

@MainActor
func isStandardChromeWindow(_ window: NSWindow) -> Bool {
    if let id = window.identifier?.rawValue {
        if id == AppWindowIdentifier.settings.rawValue
            || id == AppWindowIdentifier.about.rawValue
            || id == AppWindowIdentifier.agreement.rawValue
            || id == AppWindowIdentifier.petDex.rawValue
            || id == AppWindowIdentifier.memoryManager.rawValue
            || id == AppWindowIdentifier.gitDiff.rawValue {
            return true
        }
        if id.contains("Settings") || id.contains("settings") {
            return true
        }
    }
    return false
}

@MainActor
func isMainWorkspaceWindow(_ window: NSWindow) -> Bool {
    window.identifier == AppWindowIdentifier.main
}

@MainActor
func isDetachedTerminalWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix(AppWindowIdentifier.detachedTerminalPrefix) == true
}

@MainActor
func applyImmersiveWindowChrome(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = false
    window.backgroundColor = .clear
    window.toolbar = nil
}

@MainActor
func applyMainWorkspaceWindowChrome(_ window: NSWindow) {
    applyImmersiveWindowChrome(window)
    repositionMainWorkspaceTrafficLights(in: window)
}

@MainActor
func repositionMainWorkspaceTrafficLights(in window: NSWindow) {
    repositionTrafficLights(in: window, centerYFromTop: 22)
}

@MainActor
private func repositionTrafficLights(in window: NSWindow, centerYFromTop: CGFloat) {
    guard !(window is NSPanel) else {
        return
    }

    guard let closeButton = window.standardWindowButton(.closeButton),
          let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
          let zoomButton = window.standardWindowButton(.zoomButton) else {
        return
    }

    guard let buttonContainer = closeButton.superview else {
        return
    }

    let buttons = [closeButton, miniaturizeButton, zoomButton]
    let targetCenterY = buttonContainer.bounds.height - centerYFromTop

    for button in buttons {
        button.isHidden = false
        button.alphaValue = 1
        var frame = button.frame
        frame.origin.y = targetCenterY - frame.height / 2
        button.setFrameOrigin(frame.origin)
    }
}

struct DmuxWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.bootstrap()

    var body: some Scene {
        let _ = appDelegate.configure(model: model)

        WindowGroup {
            RootView(model: model)
        }
        .defaultSize(width: 1460, height: 920)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor
    private static var isRelaunching = false
    private weak var model: AppModel?
    private var localKeyMonitor: Any?
    private var isPreparingTermination = false
    private var hasPreparedTermination = false

    @MainActor
    static func scheduleRelaunch(at url: URL) {
        guard !isRelaunching else { return }
        isRelaunching = true

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && /usr/bin/open -n -- \"$RELAUNCH_PATH\""]
        task.environment = ["RELAUNCH_PATH": url.path]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            isRelaunching = false
        }
    }

    @MainActor
    func configure(model: AppModel) {
        self.model = model
        installLocalKeyMonitorIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        UNUserNotificationCenter.current().delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )

        for window in NSApp.windows {
            configure(window)
        }

        Task { @MainActor [weak self] in
            self?.model?.reconcileManagedAIProcessState(reason: "did-finish-launching")
            self?.model?.presentStartupRecoveryIfNeeded()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !hasPreparedTermination else {
            return .terminateNow
        }
        guard !isPreparingTermination else {
            return .terminateLater
        }

        isPreparingTermination = true
        AppDebugLog.shared.log("app", "application-should-terminate prepare")
        model?.prepareForApplicationTermination()
        Task { @MainActor [weak self] in
            await LocalLlamaRuntimeLifecycle.prepareForApplicationTermination()
            self?.hasPreparedTermination = true
            self?.isPreparingTermination = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if #available(macOS 11.0, *) {
            return [.banner, .list, .sound, .badge]
        }
        return [.sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
    }

    @MainActor
    private func installLocalKeyMonitorIfNeeded() {
        guard localKeyMonitor == nil else {
            return
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handleLocalKeyDown(event)
        }
    }

    @MainActor
    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = normalizedShortcutModifiers(for: event)
        let scope = workspaceKeyboardFocusScope(for: event)
        if handleFocusedWorkspaceShortcutIfNeeded(event, modifiers: modifiers, scope: scope) {
            return nil
        }
        if WorkspaceKeyboardRouter.shouldPreferFileBrowserShortcut(
            key: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifiers: modifiers,
            scope: scope
        ) {
            return event
        }

        let mainMenuHandled = handleMainMenuShortcutIfNeeded(event, modifiers: modifiers)
        if mainMenuHandled {
            return nil
        }

        let reservedApplicationShortcut = isReservedApplicationShortcut(event, modifiers: modifiers)
        if reservedApplicationShortcut {
            return event
        }

        guard modifiers == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            if routeKeyDownToTerminalIfNeeded(
                event,
                modifiers: modifiers,
                isMainMenuShortcut: mainMenuHandled,
                isReservedApplicationShortcut: reservedApplicationShortcut
            ) {
                return nil
            }
            return event
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return event
        }

        if isStandardChromeWindow(window) || isDetachedTerminalWindow(window) {
            window.performClose(nil)
            return nil
        }

        switch scope {
        case .fileBrowser, .fileEditor, .workspaceFiles:
            let didClose = model?.closeWorkspaceFileCommandTab() ?? false
            logKeyboardRoute(event: event, scope: scope, action: .closeFileTab, didHandle: true, result: didClose)
            return nil
        case .workspaceReview:
            return event
        case .terminal, .workspace:
            break
        }

        guard let model, model.selectedSessionID != nil else {
            return event
        }

        model.confirmCloseSelectedSession()
        return nil
    }

    @MainActor
    private func handleFocusedWorkspaceShortcutIfNeeded(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags,
        scope: WorkspaceKeyboardFocusScope
    ) -> Bool {
        guard let model,
              workspaceWindow(for: event) != nil else {
            return false
        }
        let action = WorkspaceKeyboardRouter.commandAction(
            key: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifiers: modifiers,
            scope: scope
        )
        switch action {
        case .closeFileTab:
            let didClose = model.closeWorkspaceFileCommandTab()
            logKeyboardRoute(event: event, scope: scope, action: action, didHandle: true, result: didClose)
            return true
        case .saveFileTab:
            let didSave = model.requestSaveWorkspaceFileCommandTab()
            logKeyboardRoute(event: event, scope: scope, action: action, didHandle: true, result: didSave)
            return true
        case .closeTerminalSplit:
            guard let window = workspaceWindow(for: event),
                  !isStandardChromeWindow(window),
                  !isDetachedTerminalWindow(window),
                  model.selectedSessionID != nil else {
                return false
            }
            model.confirmCloseSelectedSession()
            logKeyboardRoute(event: event, scope: scope, action: action, didHandle: true, result: true)
            return true
        case .passThrough:
            return false
        }
    }

    @MainActor
    private func workspaceKeyboardFocusScope(for event: NSEvent) -> WorkspaceKeyboardFocusScope {
        let window = workspaceWindow(for: event)
        let responder = window?.firstResponder
        let isTerminalResponder = responder.map {
            DmuxTerminalBackend.shared.registry.ownsResponder($0)
        } ?? false
        let isSystemTextResponder = responder is NSTextView
        let responderClassName = responder.map { NSStringFromClass(type(of: $0)) }
        return WorkspaceKeyboardRouter.focusScope(
            focusContext: FileBrowserKeyboardFocusState.context,
            isSelectedWorkspaceFilesModeActive: model?.isSelectedWorkspaceFilesModeActive() == true,
            isSelectedWorkspaceReviewModeActive: model?.isSelectedWorkspaceReviewModeActive() == true,
            isWorkspaceFileCommandActive: model?.isWorkspaceFileCommandActive() == true,
            isTerminalResponder: isTerminalResponder,
            isSystemTextResponder: isSystemTextResponder,
            responderClassName: responderClassName
        )
    }

    @MainActor
    private func workspaceWindow(for event: NSEvent) -> NSWindow? {
        if let window = event.window, isMainWorkspaceWindow(window) {
            return window
        }
        if let window = NSApp.keyWindow, isMainWorkspaceWindow(window) {
            return window
        }
        if let window = NSApp.mainWindow, isMainWorkspaceWindow(window) {
            return window
        }
        return nil
    }

    private func logKeyboardRoute(
        event: NSEvent,
        scope: WorkspaceKeyboardFocusScope,
        action: WorkspaceKeyboardCommandAction,
        didHandle: Bool,
        result: Bool
    ) {
        AppDebugLog.shared.log(
            "keyboard-routing",
            "key=\(WorkspaceKeyboardRouter.normalizedKey(key: event.charactersIgnoringModifiers, keyCode: event.keyCode) ?? "nil") code=\(event.keyCode) scope=\(scope.rawValue) action=\(action) handled=\(didHandle) result=\(result)"
        )
    }

    @MainActor
    private func handleMainMenuShortcutIfNeeded(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else {
            return false
        }
        guard let mainMenu = NSApp.mainMenu else {
            return false
        }
        return mainMenu.performKeyEquivalent(with: event)
    }

    @MainActor
    private func normalizedShortcutModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.remove(.numericPad)
        modifiers.remove(.function)
        modifiers.remove(.capsLock)
        return modifiers
    }

    @MainActor
    private func routeKeyDownToTerminalIfNeeded(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags,
        isMainMenuShortcut: Bool,
        isReservedApplicationShortcut: Bool
    ) -> Bool {
        guard TerminalKeyRoutingPolicy.shouldRouteToTerminal(
            isMainMenuShortcut: isMainMenuShortcut,
            isReservedApplicationShortcut: isReservedApplicationShortcut,
            isWorkspaceEditorFocused: FileBrowserKeyboardFocusState.isWorkspaceFileEditorActive || model?.isWorkspaceFileCommandActive() == true || model?.isSelectedWorkspaceFilesModeActive() == true || model?.isSelectedWorkspaceReviewModeActive() == true
        ) else {
            return false
        }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              !isStandardChromeWindow(window) else {
            return false
        }

        let responder = window.firstResponder
        let isTerminalResponder = responder.map {
            DmuxTerminalBackend.shared.registry.ownsResponder($0)
        } ?? false
        if FileBrowserKeyboardFocusState.shouldSuppressTerminalRouting,
           isTerminalResponder == false {
            return false
        }
        if responder is NSTextView,
           isTerminalResponder == false {
            return false
        }

        return DmuxTerminalBackend.shared.registry.forwardKeyDown(event, responder: responder)
    }

    @MainActor
    private func isReservedApplicationShortcut(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers == [.command] && event.charactersIgnoringModifiers?.lowercased() == ","
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApp.windows {
            configure(window)
        }
        Task { @MainActor [weak self] in
            self?.model?.reconcileManagedAIProcessState(reason: "did-become-active")
            self?.model?.presentStartupRecoveryIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDebugLog.shared.log("ghostty-lifecycle", "application-will-terminate")
        SleepPreventionService.shared.stop()
        DmuxTerminalBackend.shared.registry.terminateAll()
    }

    @objc
    @MainActor
    private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        guard !isStandardChromeWindow(window),
              !isDetachedTerminalWindow(window) else {
            return
        }

        repositionMainWorkspaceTrafficLights(in: window)
    }

    @objc
    @MainActor
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        restoreTerminalFocusIfNeeded(for: window)
    }

    @objc
    @MainActor
    private func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        restoreTerminalFocusIfNeeded(for: window)
    }

    @MainActor
    private func configure(_ window: NSWindow) {
        guard !(window is NSPanel) else {
            return
        }

        window.isRestorable = false

        if isStandardChromeWindow(window) {
            applyStandardWindowChrome(window, toolbarStyle: .preference)
            return
        }

        if isDetachedTerminalWindow(window) {
            applyStandardWindowChrome(window)
            return
        }

        guard isMainWorkspaceWindow(window) else {
            return
        }

        applyMainWorkspaceWindowChrome(window)
    }

    @MainActor
    private func restoreTerminalFocusIfNeeded(for window: NSWindow) {
        guard !(window is NSPanel),
              !isStandardChromeWindow(window),
              !isDetachedTerminalWindow(window) else {
            return
        }
        guard model?.isWorkspaceFileCommandActive() != true,
              model?.isSelectedWorkspaceFilesModeActive() != true else {
            return
        }
        model?.restoreSelectedTerminalFocusIfNeeded()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
