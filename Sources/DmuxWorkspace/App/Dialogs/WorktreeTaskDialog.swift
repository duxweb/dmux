import AppKit
import SwiftUI

private final class WorktreeTaskPanelViewModel: ObservableObject {
    @Published var baseBranch: String
    @Published var branchName: String
    @Published var taskTitle: String
    var onConfirm: ((WorktreeTaskDialogResult) -> Void)?
    var onCancel: (() -> Void)?

    init(dialog: WorktreeTaskDialogState) {
        self.baseBranch = dialog.baseBranch
        self.branchName = dialog.branchName
        self.taskTitle = dialog.taskTitle
    }
}

private struct WorktreeTaskPanelView: View {
    let dialog: WorktreeTaskDialogState
    @ObservedObject var viewModel: WorktreeTaskPanelViewModel
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isBranchFocused: Bool

    private var header: AppDialogHeaderSpec {
        AppDialogHeaderSpec(
            title: dialog.title,
            message: dialog.message,
            icon: nil,
            iconColor: AppTheme.focus
        )
    }

    private var isConfirmDisabled: Bool {
        viewModel.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            viewModel.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            viewModel.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AppDialogFormLayout(
            header: header,
            width: 520,
            chromeTopInset: 6,
            contentSpacing: 16,
            headerTopPadding: 18,
            headerBottomPadding: 14,
            contentTopPadding: 8,
            contentBottomPadding: 18,
            footerTopPadding: 4,
            footerBottomPadding: 18
        ) {
            underlineField(
                title: String(localized: "worktree.task.title", defaultValue: "Task Title", bundle: .module),
                text: $viewModel.taskTitle,
                placeholder: "",
                isFocused: isTitleFocused,
                monospace: false
            )
            .focused($isTitleFocused)

            pickerColumn(
                title: String(localized: "worktree.task.base_branch", defaultValue: "Base Branch", bundle: .module)
            ) {
                Picker("", selection: $viewModel.baseBranch) {
                    ForEach(dialog.baseBranches, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            underlineField(
                title: String(localized: "worktree.task.branch", defaultValue: "Task Branch", bundle: .module),
                text: $viewModel.branchName,
                placeholder: "task/editor-review",
                isFocused: isBranchFocused,
                monospace: true
            )
            .focused($isBranchFocused)

        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)) { viewModel.onCancel?() }
                .buttonStyle(AppDialogSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button(dialog.confirmTitle) {
                submitIfValid()
            }
            .buttonStyle(AppDialogPrimaryButtonStyle())
            .disabled(isConfirmDisabled)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTitleFocused = true
            }
        }
    }

    private func underlineField(
        title: String,
        text: Binding<String>,
        placeholder: String,
        isFocused: Bool,
        monospace: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            TextField(
                "",
                text: text,
                prompt: Text(placeholder).foregroundStyle(Color(nsColor: .placeholderTextColor))
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: monospace ? .monospaced : .default))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(height: 26)
            Rectangle()
                .fill(isFocused
                      ? AppTheme.focus.opacity(0.7)
                      : Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: isFocused ? 1.5 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }

    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            content()
        }
    }

    private func submitIfValid() {
        guard !isConfirmDisabled else { return }
        viewModel.onConfirm?(
            WorktreeTaskDialogResult(
                baseBranch: viewModel.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines),
                branchName: viewModel.branchName.trimmingCharacters(in: .whitespacesAndNewlines),
                taskTitle: viewModel.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}

final class WorktreeTaskPanelController: AppDialogController<WorktreeTaskDialogResult> {
    private let viewModel: WorktreeTaskPanelViewModel

    init(dialog: WorktreeTaskDialogState) {
        self.viewModel = WorktreeTaskPanelViewModel(dialog: dialog)

        let width: CGFloat = 520
        let height: CGFloat = 300
        let panel = AppDialogPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.title = dialog.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(panel: panel)

        let contentView = WorktreeTaskPanelView(dialog: dialog, viewModel: viewModel)
            .frame(width: width, alignment: .topLeading)
        let hostingController = NSHostingController(rootView: contentView)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: width, height: height))
        panel.minSize = NSSize(width: width, height: height)
        panel.maxSize = NSSize(width: width, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForPresentation() {
        viewModel.onConfirm = { [weak self] result in
            self?.finish(with: .continue, value: result)
        }
        viewModel.onCancel = { [weak self] in
            self?.finish(with: .abort)
        }
    }
}
