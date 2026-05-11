import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum BottomTabDragPayload {
    static let type = UTType.text.identifier

    static func provider(for sessionID: UUID) -> NSItemProvider {
        NSItemProvider(object: sessionID.uuidString as NSString)
    }
}

struct TopPaneRowView: View {
    let model: AppModel
    let workspace: ProjectWorkspace
    let activeTerminalSessionID: UUID?
    let showsInactiveOverlay: Bool
    let isVisible: Bool

    var body: some View {
        TopPaneSplitContainer(
            model: model,
            workspace: workspace,
            activeTerminalSessionID: activeTerminalSessionID,
            showsInactiveOverlay: showsInactiveOverlay,
            isVisible: isVisible
        )
    }
}

struct TopPaneSplitContainer: NSViewControllerRepresentable {
    let model: AppModel
    let workspace: ProjectWorkspace
    let activeTerminalSessionID: UUID?
    let showsInactiveOverlay: Bool
    let isVisible: Bool

    func makeNSViewController(context: Context) -> TopPaneSplitController {
        TopPaneSplitController(
            model: model,
            workspace: workspace,
            activeTerminalSessionID: activeTerminalSessionID,
            showsInactiveOverlay: showsInactiveOverlay,
            isVisible: isVisible,
            dividerColor: model.terminalDividerNSColor
        )
    }

    func updateNSViewController(_ controller: TopPaneSplitController, context: Context) {
        controller.update(
            workspace: workspace,
            activeTerminalSessionID: activeTerminalSessionID,
            showsInactiveOverlay: showsInactiveOverlay,
            isVisible: isVisible,
            dividerColor: model.terminalDividerNSColor
        )
    }
}

final class TopPaneSplitController: NSViewController, NSSplitViewDelegate {
    private let model: AppModel
    private let paneSplitView = DividerStyledHorizontalSplitView()
    private var paneHosts: [UUID: NSHostingController<TerminalPaneView>] = [:]
    private var lastRenderedSessionByID: [UUID: TerminalSession] = [:]
    private var currentSessionIDs: [UUID] = []
    private var currentWorkspace: ProjectWorkspace
    private var activeTerminalSessionID: UUID?
    private var lastRenderedFocusedSessionID: UUID?
    private var showsInactiveOverlay: Bool
    private var lastRenderedShowsInactiveOverlay: Bool
    private var isVisible: Bool
    private var lastRenderedIsVisible: Bool
    private var dividerColor: NSColor
    private let minimumPaneWidth: CGFloat = 220
    private var isApplyingLayout = false
    private var hasAppliedInitialRatios = false
    init(model: AppModel, workspace: ProjectWorkspace, activeTerminalSessionID: UUID?, showsInactiveOverlay: Bool, isVisible: Bool, dividerColor: NSColor) {
        self.model = model
        self.currentWorkspace = workspace
        self.activeTerminalSessionID = activeTerminalSessionID
        self.showsInactiveOverlay = showsInactiveOverlay
        self.lastRenderedShowsInactiveOverlay = showsInactiveOverlay
        self.isVisible = isVisible
        self.lastRenderedIsVisible = isVisible
        self.dividerColor = dividerColor
        super.init(nibName: nil, bundle: nil)
        paneSplitView.dividerStyle = NSSplitView.DividerStyle.thin
        paneSplitView.isVertical = true
        paneSplitView.delegate = self
        paneSplitView.customDividerColor = dividerColor
        paneSplitView.isDividerInteractive = isVisible && workspace.topSessionIDs.count > 1
        rebuildPanes(for: workspace)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paneSplitView)

        NSLayoutConstraint.activate([
            paneSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            paneSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyRatiosIfNeeded()
    }

    func update(workspace: ProjectWorkspace, activeTerminalSessionID: UUID?, showsInactiveOverlay: Bool, isVisible: Bool, dividerColor: NSColor) {
        let shouldResetPaneDistribution = Self.shouldResetTopPaneDistribution(
            from: currentWorkspace,
            to: workspace
        )
        let sessionIDsChanged = workspace.topSessionIDs != currentWorkspace.topSessionIDs
        currentWorkspace = workspace
        self.activeTerminalSessionID = activeTerminalSessionID
        self.showsInactiveOverlay = showsInactiveOverlay
        self.isVisible = isVisible
        self.dividerColor = dividerColor
        paneSplitView.customDividerColor = dividerColor
        paneSplitView.isDividerInteractive = isVisible && workspace.topSessionIDs.count > 1
        if sessionIDsChanged {
            if shouldResetPaneDistribution {
                let equal = 1 / CGFloat(max(workspace.topSessionIDs.count, 1))
                model.updateTopPaneRatios(Array(repeating: equal, count: workspace.topSessionIDs.count))
            }
            rebuildPanes(for: workspace)
        }
        updatePaneViews(for: workspace)
        applyRatiosIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.applyRatiosIfNeeded()
        }
    }

    private func rebuildPanes(for workspace: ProjectWorkspace) {
        guard currentSessionIDs != workspace.topSessionIDs else { return }
        currentSessionIDs = workspace.topSessionIDs
        hasAppliedInitialRatios = false

        let activeSessionIDs = Set(workspace.topSessionIDs)
        let inactiveSessionIDs = Set(paneHosts.keys).subtracting(activeSessionIDs)
        for sessionID in inactiveSessionIDs {
            if let host = paneHosts[sessionID] {
                detachPaneHostView(host.view)
            }
        }

        let obsoleteSessionIDs = inactiveSessionIDs.filter { model.terminalSession(for: $0) == nil }
        for sessionID in obsoleteSessionIDs {
            if let host = paneHosts.removeValue(forKey: sessionID) {
                host.removeFromParent()
            }
            lastRenderedSessionByID.removeValue(forKey: sessionID)
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0) })

        for (index, sessionID) in workspace.topSessionIDs.enumerated() {
            guard let session = sessionsByID[sessionID] else { continue }

            let host: NSHostingController<TerminalPaneView>
            if let existing = paneHosts[sessionID] {
                host = existing
                host.rootView = makePaneView(session: session, sessionID: sessionID)
                lastRenderedSessionByID[sessionID] = session
            } else {
                host = NSHostingController(
                    rootView: makePaneView(session: session, sessionID: sessionID)
                )
                paneHosts[sessionID] = host
                lastRenderedSessionByID[sessionID] = session
            }

            if host.parent == nil {
                addChild(host)
            }

            if paneSplitView.arrangedSubviews.contains(host.view) == false {
                paneSplitView.insertArrangedSubview(host.view, at: min(index, paneSplitView.arrangedSubviews.count))
            } else if index >= paneSplitView.arrangedSubviews.count || paneSplitView.arrangedSubviews[index] !== host.view {
                detachPaneHostView(host.view)
                paneSplitView.insertArrangedSubview(host.view, at: index)
            }
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = [.width, .height]
        }

        lastRenderedFocusedSessionID = activeTerminalSessionID

        DispatchQueue.main.async { [weak self] in
            self?.applyRatiosIfNeeded()
        }
    }

    private func detachPaneHostView(_ view: NSView) {
        if paneSplitView.arrangedSubviews.contains(view) {
            paneSplitView.removeArrangedSubview(view)
        }
        view.removeFromSuperview()
    }

    private func updatePaneViews(for workspace: ProjectWorkspace) {
        let sessionsByID = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0) })
        var sessionsToUpdate = Set<UUID>()

        if lastRenderedShowsInactiveOverlay != showsInactiveOverlay || lastRenderedIsVisible != isVisible {
            sessionsToUpdate.formUnion(workspace.topSessionIDs)
        } else {
            sessionsToUpdate.formUnion([lastRenderedFocusedSessionID, activeTerminalSessionID].compactMap { $0 })
        }

        for sessionID in workspace.topSessionIDs {
            guard let session = sessionsByID[sessionID] else { continue }
            if lastRenderedSessionByID[sessionID] != session {
                sessionsToUpdate.insert(sessionID)
            }
        }

        for sessionID in sessionsToUpdate {
            guard let session = sessionsByID[sessionID], let host = paneHosts[sessionID] else { continue }
            host.rootView = makePaneView(session: session, sessionID: sessionID)
            lastRenderedSessionByID[sessionID] = session
        }

        lastRenderedFocusedSessionID = activeTerminalSessionID
        lastRenderedShowsInactiveOverlay = showsInactiveOverlay
        lastRenderedIsVisible = isVisible
    }

    private func makePaneView(session: TerminalSession, sessionID: UUID) -> TerminalPaneView {
        TerminalPaneView(
            model: model,
            session: session,
            terminalBackgroundPreset: model.terminalBackgroundPreset,
            backgroundColorPreset: model.backgroundColorPreset,
            isFocused: sessionID == activeTerminalSessionID,
            isVisible: isVisible,
            showsInactiveOverlay: showsInactiveOverlay,
            onSelect: { self.model.selectSession(sessionID) },
            onClose: { self.model.closeSession(sessionID) },
            onDetach: { self.model.detachSession(sessionID) },
            onTaskMemos: { self.model.openTaskMemoPanel(for: sessionID) },
            showsCloseButton: true
        )
    }

    private func applyRatiosIfNeeded() {
        guard !isApplyingLayout, paneSplitView.bounds.width > 0, currentSessionIDs.count > 1 else { return }
        let ratios = currentWorkspace.resolvedTopPaneRatios()
        guard ratios.count == currentSessionIDs.count else { return }

        isApplyingLayout = true
        defer { isApplyingLayout = false }

        let dividerCount = max(0, currentSessionIDs.count - 1)
        let availableWidth = max(0, paneSplitView.bounds.width - CGFloat(dividerCount))
        var runningX: CGFloat = 0

        for index in 0 ..< dividerCount {
            runningX += availableWidth * ratios[index]
            paneSplitView.setPosition(runningX, ofDividerAt: index)
            runningX += paneSplitView.dividerThickness
        }

        paneSplitView.adjustSubviews()
        hasAppliedInitialRatios = true
    }

    static func shouldResetTopPaneDistribution(from currentWorkspace: ProjectWorkspace, to nextWorkspace: ProjectWorkspace) -> Bool {
        currentWorkspace.projectID == nextWorkspace.projectID &&
            currentWorkspace.topSessionIDs != nextWorkspace.topSessionIDs
    }

    static func shouldCommitTopPaneRatios(
        isApplyingLayout: Bool,
        hasAppliedInitialRatios: Bool,
        isUserDraggingDivider: Bool,
        isVisible: Bool,
        topSessionCount: Int,
        selectedWorktreeID: UUID?,
        currentWorkspaceProjectID: UUID
    ) -> Bool {
        !isApplyingLayout &&
            hasAppliedInitialRatios &&
            isUserDraggingDivider &&
            isVisible &&
            topSessionCount > 1 &&
            selectedWorktreeID == currentWorkspaceProjectID
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard Self.shouldCommitTopPaneRatios(
            isApplyingLayout: isApplyingLayout,
            hasAppliedInitialRatios: hasAppliedInitialRatios,
            isUserDraggingDivider: paneSplitView.isTrackingDividerDrag,
            isVisible: isVisible,
            topSessionCount: currentSessionIDs.count,
            selectedWorktreeID: model.selectedWorktreeID,
            currentWorkspaceProjectID: currentWorkspace.projectID
        ) else { return }

        let widths = paneSplitView.subviews.prefix(currentSessionIDs.count).map { $0.frame.width }
        let total = widths.reduce(0, +)
        guard total > 0 else { return }
        model.updateTopPaneRatios(widths.map { $0 / total })
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let previousEdge = dividerIndex == 0 ? 0 : paneSplitView.subviews[dividerIndex - 1].frame.maxX + paneSplitView.dividerThickness
        return previousEdge + minimumPaneWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let nextFrame = paneSplitView.subviews[dividerIndex + 1].frame
        return nextFrame.maxX - minimumPaneWidth - paneSplitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        splitView.coduxExpandedDividerRect(at: dividerIndex)
    }
}

struct BottomTabbedPaneView: View {
    let model: AppModel
    let workspace: ProjectWorkspace
    let activeTerminalSessionID: UUID?
    let showsInactiveOverlay: Bool
    let isVisible: Bool

    static let statusBarHeight = WorkspaceVerticalSplitMetrics.collapsedBottomHeight
    @State private var draggingBottomTabSessionID: UUID?
    @State private var didReorderBottomTabs = false

    private var selectedBottomSessionID: UUID? {
        if let selected = workspace.selectedBottomTabSessionID,
           workspace.bottomTabSessionIDs.contains(selected) {
            return selected
        }
        return workspace.bottomTabSessionIDs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if workspace.hasBottomTabs {
                bottomTerminalContent
            }
        }
        .background(
            Rectangle()
                .fill(model.terminalChromeColor)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if workspace.hasBottomTabs {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(workspace.bottomTabSessionIDs.enumerated()), id: \.element) { index, sessionID in
                            let isSelected = sessionID == selectedBottomSessionID

                            TabChip(
                                model: model,
                                title: model.bottomTabDisplayTitle(sessionID: sessionID, fallbackIndex: index),
                                sessionID: sessionID,
                                isSelected: isSelected,
                                draggingSessionID: $draggingBottomTabSessionID,
                                onSelect: { model.selectBottomTabSession(sessionID) },
                                onRename: { model.renameBottomTabSession(sessionID) },
                                onClose: { model.closeSession(sessionID) },
                                onMove: { draggedSessionID in
                                    model.moveBottomTabSession(draggedSessionID, to: sessionID, persists: false)
                                },
                                onFinishMove: {
                                    guard didReorderBottomTabs else { return }
                                    didReorderBottomTabs = false
                                    model.scheduleBottomTabOrderPersist()
                                },
                                didMove: { didReorderBottomTabs = true }
                            )
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "workspace.bottom_terminal.title", defaultValue: "Terminal", bundle: .module))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(model.terminalMutedTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            bottomTabAddButton
        }
        .padding(.horizontal, 10)
        .frame(height: workspace.hasBottomTabs ? 46 : Self.statusBarHeight)
        .background(
            Rectangle()
                .fill(model.terminalChromeColor)
        )
    }

    private var bottomTerminalContent: some View {
        ZStack {
            if let selectedBottomSessionID,
               let session = workspace.sessions.first(where: { $0.id == selectedBottomSessionID }) {
                TerminalPaneView(
                    model: model,
                    session: session,
                    terminalBackgroundPreset: model.terminalBackgroundPreset,
                    backgroundColorPreset: model.backgroundColorPreset,
                    isFocused: selectedBottomSessionID == activeTerminalSessionID,
                    isVisible: isVisible,
                    showsInactiveOverlay: showsInactiveOverlay,
                    onSelect: { model.selectBottomTabSession(selectedBottomSessionID) },
                    onClose: { model.closeSession(selectedBottomSessionID) },
                    onDetach: nil,
                    onTaskMemos: { model.openTaskMemoPanel(for: selectedBottomSessionID) },
                    showsCloseButton: false
                )
            }
        }
        .background(
            Rectangle()
                .fill(model.terminalChromeColor)
        )
    }

    private var bottomTabAddButton: some View {
        Button(action: model.createBottomTab) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.terminalMutedTextColor)
                .frame(width: 22, height: 22)
                .background(model.terminalUsesLightBackground ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct VerticalTerminalSplitView<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let model: AppModel
    let workspace: ProjectWorkspace
    let dividerColor: NSColor
    let hasBottomRegion: Bool
    let bottomHeight: CGFloat
    let isVisible: Bool
    let top: () -> Top
    let bottom: () -> Bottom

    func makeNSViewController(context: Context) -> SplitViewController<Top, Bottom> {
        SplitViewController(model: model, workspace: workspace, dividerColor: dividerColor, hasBottomRegion: hasBottomRegion, bottomHeight: bottomHeight, isVisible: isVisible, top: top(), bottom: bottom())
    }

    func updateNSViewController(_ controller: SplitViewController<Top, Bottom>, context: Context) {
        controller.update(workspace: workspace, top: top(), bottom: bottom(), dividerColor: dividerColor, hasBottomRegion: hasBottomRegion, bottomHeight: bottomHeight, isVisible: isVisible)
    }
}

enum WorkspaceVerticalSplitMetrics {
    static let collapsedBottomHeight: CGFloat = 40

    static func minimumDividerCoordinate(totalHeight: CGFloat, hasBottomRegion: Bool, hasBottomTabs: Bool) -> CGFloat {
        guard hasBottomRegion else { return 0 }
        guard hasBottomTabs else {
            return collapsedBottomHeight
        }
        return ProjectWorkspace.minimumBottomPaneHeight
    }

    static func maximumDividerCoordinate(totalHeight: CGFloat, hasBottomRegion: Bool, hasBottomTabs: Bool) -> CGFloat {
        guard hasBottomRegion else { return 0 }
        guard hasBottomTabs else {
            return collapsedBottomHeight
        }
        let maximum = max(0, totalHeight - ProjectWorkspace.minimumBottomPaneHeight)
        let topConstrainedMaximum = max(0, totalHeight - ProjectWorkspace.minimumTopPaneHeight)
        return max(ProjectWorkspace.minimumBottomPaneHeight, min(maximum, topConstrainedMaximum))
    }

    static func clampedBottomHeight(requested: CGFloat, totalHeight: CGFloat, hasBottomTabs: Bool) -> CGFloat {
        guard totalHeight > 0 else {
            return hasBottomTabs ? ProjectWorkspace.minimumBottomPaneHeight : collapsedBottomHeight
        }
        let minimumBottomHeight = hasBottomTabs
            ? ProjectWorkspace.minimumBottomPaneHeight
            : collapsedBottomHeight
        return min(
            max(requested, minimumBottomHeight),
            max(minimumBottomHeight, totalHeight - ProjectWorkspace.minimumTopPaneHeight)
        )
    }

    static func dividerPosition(forBottomHeight bottomHeight: CGFloat, totalHeight: CGFloat, hasBottomTabs: Bool) -> CGFloat {
        guard totalHeight > 0 else {
            return 0
        }
        return clampedBottomHeight(requested: bottomHeight, totalHeight: totalHeight, hasBottomTabs: hasBottomTabs)
    }
}

final class SplitViewController<Top: View, Bottom: View>: NSViewController {
    private unowned let model: AppModel
    private let splitView = VerticalBottomSplitHostView()
    private let topHosting = NSHostingController(rootView: AnyView(EmptyView()))
    private let bottomHosting = NSHostingController(rootView: AnyView(EmptyView()))
    private var currentWorkspace: ProjectWorkspace
    private var dividerColor: NSColor
    private var hasBottomRegion: Bool
    private var bottomHeight: CGFloat
    private var isVisible: Bool
    private var isApplyingLayout = false
    private var hasCommittedInitialBottomLayout = false
    init(model: AppModel, workspace: ProjectWorkspace, dividerColor: NSColor, hasBottomRegion: Bool, bottomHeight: CGFloat, isVisible: Bool, top: Top, bottom: Bottom) {
        self.model = model
        self.currentWorkspace = workspace
        self.dividerColor = dividerColor
        self.hasBottomRegion = hasBottomRegion
        self.bottomHeight = bottomHeight
        self.isVisible = isVisible
        super.init(nibName: nil, bundle: nil)
        splitView.customDividerColor = dividerColor
        topHosting.rootView = AnyView(top)
        bottomHosting.rootView = AnyView(bottom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = splitView
        addChild(topHosting)
        addChild(bottomHosting)
        splitView.install(topView: topHosting.view, bottomView: bottomHosting.view)
        splitView.onBottomHeightChanged = { [weak self] height, availableHeight in
            guard let self else {
                return
            }
            self.bottomHeight = height
            guard !self.isApplyingLayout,
                  self.isVisible,
                  self.hasBottomRegion,
                  self.currentWorkspace.hasBottomTabs,
                  self.hasCommittedInitialBottomLayout else {
                return
            }
            self.model.updateBottomPaneHeight(
                height,
                for: self.currentWorkspace.projectID,
                availableHeight: availableHeight
            )
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyBottomHeightIfNeeded()
    }

    func update(workspace: ProjectWorkspace, top: Top, bottom: Bottom, dividerColor: NSColor, hasBottomRegion: Bool, bottomHeight: CGFloat, isVisible: Bool) {
        if currentWorkspace.projectID != workspace.projectID {
            hasCommittedInitialBottomLayout = false
        }
        currentWorkspace = workspace
        self.dividerColor = dividerColor
        self.hasBottomRegion = hasBottomRegion
        self.isVisible = isVisible
        topHosting.rootView = AnyView(top)
        bottomHosting.rootView = AnyView(bottom)
        splitView.customDividerColor = dividerColor
        self.bottomHeight = bottomHeight
        applyBottomHeightIfNeeded()
        splitView.needsDisplay = true
    }

    private func applyBottomHeightIfNeeded() {
        guard view.bounds.height > 0, !isApplyingLayout else { return }
        isApplyingLayout = true
        defer { isApplyingLayout = false }

        splitView.isDividerInteractive = isVisible && hasBottomRegion && currentWorkspace.hasBottomTabs
        splitView.configure(
            hasBottomRegion: hasBottomRegion,
            hasBottomTabs: currentWorkspace.hasBottomTabs,
            bottomHeight: bottomHeight,
            dividerColor: hasBottomRegion ? dividerColor : .clear
        )
        hasCommittedInitialBottomLayout = hasBottomRegion
    }

}

private final class VerticalBottomSplitHostView: NSView, CoduxSplitDividerHitRegionProviding {
    var customDividerColor: NSColor = .separatorColor {
        didSet {
            guard oldValue.isEqual(customDividerColor) == false else {
                return
            }
            dividerHandleView.dividerColor = customDividerColor
        }
    }
    var isDividerInteractive = true {
        didSet {
            guard oldValue != isDividerInteractive else {
                return
            }
            dividerHandleView.isInteractive = isDividerInteractive
        }
    }
    var onBottomHeightChanged: ((CGFloat, CGFloat) -> Void)?

    private let dividerHandleView = VerticalBottomSplitDividerHandleView()
    private weak var topView: NSView?
    private weak var bottomView: NSView?
    private var hasBottomRegion = true
    private var hasBottomTabs = false
    private var targetBottomHeight = ProjectWorkspace.defaultBottomPaneHeight
    private let dividerHandleHeight: CGFloat = 24
    private let dividerLineHeight: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        dividerHandleView.dividerColor = customDividerColor
        dividerHandleView.onDrag = { [weak self] boundaryY in
            self?.setBottomHeightFromDrag(boundaryY)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(topView: NSView, bottomView: NSView) {
        self.topView = topView
        self.bottomView = bottomView
        topView.translatesAutoresizingMaskIntoConstraints = true
        bottomView.translatesAutoresizingMaskIntoConstraints = true
        topView.autoresizingMask = []
        bottomView.autoresizingMask = []
        topView.wantsLayer = true
        bottomView.wantsLayer = true
        topView.layer?.masksToBounds = true
        bottomView.layer?.masksToBounds = true
        addSubview(topView)
        addSubview(bottomView)
        addSubview(dividerHandleView)
    }

    func configure(hasBottomRegion: Bool, hasBottomTabs: Bool, bottomHeight: CGFloat, dividerColor: NSColor) {
        var shouldRelayout = false
        if self.hasBottomRegion != hasBottomRegion {
            self.hasBottomRegion = hasBottomRegion
            shouldRelayout = true
        }
        if self.hasBottomTabs != hasBottomTabs {
            self.hasBottomTabs = hasBottomTabs
            shouldRelayout = true
        }
        customDividerColor = dividerColor
        dividerHandleView.isInteractive = isDividerInteractive && hasBottomRegion && hasBottomTabs
        if abs(targetBottomHeight - bottomHeight) > 0.5 {
            targetBottomHeight = bottomHeight
            shouldRelayout = true
        }
        if shouldRelayout {
            needsLayout = true
        }
    }

    func coduxSplitDividerHitRegions() -> [CoduxSplitDividerHitRegion] {
        guard hasBottomRegion,
              hasBottomTabs,
              dividerHandleView.isHidden == false else {
            return []
        }
        return [
            CoduxSplitDividerHitRegion(
                rect: dividerHandleView.frame,
                cursor: .resizeUpDown,
                targetView: dividerHandleView
            ),
        ]
    }

    override func layout() {
        super.layout()
        layoutHostedViews()
    }

    private func layoutHostedViews() {
        guard let topView, let bottomView else {
            return
        }

        let totalHeight = bounds.height
        let bottomHeight = resolvedBottomHeight(forTotalHeight: totalHeight)

        if !hasBottomRegion {
            bottomView.alphaValue = 0
            bottomView.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 0)
            dividerHandleView.isHidden = true
            topView.frame = bounds
            return
        }

        bottomView.alphaValue = 1
        dividerHandleView.isHidden = false
        bottomView.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bottomHeight)

        let topY = bottomHeight + dividerLineHeight
        let topHeight = max(0, totalHeight - topY)
        topView.frame = NSRect(x: bounds.minX, y: topY, width: bounds.width, height: topHeight)

        let dividerFrame = NSRect(
            x: bounds.minX,
            y: max(bounds.minY, bottomHeight - dividerHandleHeight / 2),
            width: bounds.width,
            height: dividerHandleHeight
        )
        if dividerHandleView.frame != dividerFrame {
            dividerHandleView.frame = dividerFrame
            window?.invalidateCursorRects(for: dividerHandleView)
        }
    }

    private func setBottomHeightFromDrag(_ boundaryY: CGFloat) {
        guard hasBottomRegion, hasBottomTabs, bounds.height > 0 else {
            return
        }
        let clamped = WorkspaceVerticalSplitMetrics.clampedBottomHeight(
            requested: boundaryY,
            totalHeight: bounds.height,
            hasBottomTabs: true
        )
        targetBottomHeight = clamped
        layoutHostedViews()
        needsLayout = true
        onBottomHeightChanged?(clamped, bounds.height)
    }

    private func resolvedBottomHeight(forTotalHeight totalHeight: CGFloat) -> CGFloat {
        guard hasBottomRegion else {
            return 0
        }
        let requestedHeight = hasBottomTabs ? targetBottomHeight : WorkspaceVerticalSplitMetrics.collapsedBottomHeight
        return WorkspaceVerticalSplitMetrics.clampedBottomHeight(
            requested: requestedHeight,
            totalHeight: totalHeight,
            hasBottomTabs: hasBottomTabs
        )
    }
}

private final class VerticalBottomSplitDividerHandleView: NSView {
    var dividerColor: NSColor = .separatorColor {
        didSet {
            guard oldValue.isEqual(dividerColor) == false else {
                return
            }
            needsDisplay = true
        }
    }
    var isInteractive = true {
        didSet {
            guard oldValue != isInteractive else {
                return
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onDrag: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isInteractive {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isInteractive {
            NSCursor.resizeUpDown.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if isInteractive {
            NSCursor.resizeUpDown.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else {
            return
        }
        NSCursor.resizeUpDown.set()
        updateHeight(with: event)
        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                break
            }
            NSCursor.resizeUpDown.set()
            updateHeight(with: nextEvent)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        dividerColor.setFill()
        NSRect(x: bounds.minX, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    private func updateHeight(with event: NSEvent) {
        guard let superview else {
            return
        }
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(point.y)
    }
}

private struct TabChip: View {
    let model: AppModel
    let title: String
    let sessionID: UUID
    let isSelected: Bool
    @Binding var draggingSessionID: UUID?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onMove: (UUID) -> Void
    let onFinishMove: () -> Void
    let didMove: () -> Void

    @State private var isHovered = false
    @State private var isDropTarget = false

    private var isDragging: Bool {
        draggingSessionID == sessionID
    }

    private var showsDropTarget: Bool {
        isDropTarget && draggingSessionID != nil && draggingSessionID != sessionID
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? model.terminalTextColor : model.terminalMutedTextColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(model.terminalMutedTextColor)
                        .opacity(isHovered || isSelected ? 1.0 : 0.0)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .appCursor(.pointingHand)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 84, minHeight: 28)
            .background(isSelected ? selectedFill : (isHovered ? hoverFill : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(showsDropTarget ? AppTheme.focus.opacity(0.86) : (isSelected ? selectedStroke : Color.clear), lineWidth: showsDropTarget ? 1.4 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.48 : 1.0)
        .contextMenu {
            Button(String(localized: "common.rename", defaultValue: "Rename", bundle: .module), action: onRename)
            Button(String(localized: "common.close", defaultValue: "Close", bundle: .module), role: .destructive, action: onClose)
        }
        .onDrag {
            draggingSessionID = sessionID
            return BottomTabDragPayload.provider(for: sessionID)
        } preview: {
            Color.white.opacity(0.001).frame(width: 1, height: 1)
        }
        .onDrop(
            of: [BottomTabDragPayload.type],
            delegate: BottomTabReorderDropDelegate(
                targetSessionID: sessionID,
                draggingSessionID: $draggingSessionID,
                isDropTarget: $isDropTarget,
                onMove: onMove,
                onFinishMove: onFinishMove,
                didMove: didMove
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var hoverFill: Color {
        model.terminalUsesLightBackground ? Color.black.opacity(0.04) : Color.white.opacity(0.05)
    }

    private var selectedFill: Color {
        model.terminalUsesLightBackground ? Color.black.opacity(0.07) : Color.white.opacity(0.11)
    }

    private var selectedStroke: Color {
        model.terminalUsesLightBackground ? Color.black.opacity(0.12) : Color.white.opacity(0.1)
    }
}

private struct BottomTabReorderDropDelegate: DropDelegate {
    let targetSessionID: UUID
    @Binding var draggingSessionID: UUID?
    @Binding var isDropTarget: Bool
    let onMove: (UUID) -> Void
    let onFinishMove: () -> Void
    let didMove: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingSessionID,
              draggingSessionID != targetSessionID else {
            return
        }
        isDropTarget = true
        move(draggingSessionID)
    }

    private func move(_ draggedSessionID: UUID) {
        withAnimation(.snappy(duration: 0.16)) {
            onMove(draggedSessionID)
        }
        didMove()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isDropTarget = false
            draggingSessionID = nil
        }
        onFinishMove()
        return true
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }
}
