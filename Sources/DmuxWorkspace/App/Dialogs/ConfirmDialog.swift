import AppKit
import SwiftUI

private struct ConfirmDialogView: View {
    let dialog: ConfirmDialogState
    let onAction: (ConfirmDialogResult, Bool) -> Void
    @State private var isOptionEnabled: Bool

    private var header: AppDialogHeaderSpec {
        AppDialogHeaderSpec(title: dialog.title, message: dialog.message, icon: dialog.icon, iconColor: dialog.iconColor)
    }

    init(dialog: ConfirmDialogState, onAction: @escaping (ConfirmDialogResult, Bool) -> Void) {
        self.dialog = dialog
        self.onAction = onAction
        _isOptionEnabled = State(initialValue: dialog.option?.isOn ?? false)
    }

    var body: some View {
        AppDialogFormLayout(
            header: header,
            width: 440,
            chromeTopInset: 8,
            contentSpacing: 0,
            headerTopPadding: 20,
            headerBottomPadding: 12,
            contentTopPadding: 0,
            contentBottomPadding: 4,
            footerTopPadding: 12,
            footerBottomPadding: 18
        ) {
            if let option = dialog.option {
                Toggle(option.title, isOn: $isOptionEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                EmptyView()
            }
        } actions: {
            if let cancelTitle = dialog.cancelTitle {
                Button(cancelTitle) { onAction(.cancel, isOptionEnabled) }
                    .buttonStyle(AppDialogSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            if let secondaryTitle = dialog.secondaryTitle {
                Button(secondaryTitle) { onAction(.secondary, isOptionEnabled) }
                    .buttonStyle(AppDialogSecondaryButtonStyle())

                Button(dialog.primaryTitle) { onAction(.primary, isOptionEnabled) }
                    .buttonStyle(AppDialogPrimaryButtonStyle(tint: dialog.primaryTint))
            } else {
                Button(dialog.primaryTitle) { onAction(.primary, isOptionEnabled) }
                    .buttonStyle(AppDialogPrimaryButtonStyle(tint: dialog.primaryTint))
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

@MainActor
private func makeConfirmDialogPanel(initialHeight: CGFloat) -> AppDialogPanel {
    let panel = AppDialogPanel(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: initialHeight),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.isFloatingPanel = false
    panel.level = .normal
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.moveToActiveSpace]
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    return panel
}

@MainActor
private func installConfirmDialogContent<Content: View>(_ contentView: Content, in panel: AppDialogPanel) {
    let hostingController = NSHostingController(rootView: contentView)
    hostingController.view.frame = NSRect(x: 0, y: 0, width: 440, height: 1)
    hostingController.view.autoresizingMask = [.width, .height]
    hostingController.view.layoutSubtreeIfNeeded()
    let contentHeight = max(1, hostingController.view.fittingSize.height)

    panel.contentViewController = hostingController
    panel.setContentSize(NSSize(width: 440, height: contentHeight))
    panel.minSize = NSSize(width: 440, height: contentHeight)
    panel.maxSize = NSSize(width: 440, height: contentHeight)
}

final class ConfirmDialogController: AppDialogController<ConfirmDialogResult> {
    init(dialog: ConfirmDialogState) {
        let panel = makeConfirmDialogPanel(initialHeight: 200)
        super.init(panel: panel)

        let contentView = ConfirmDialogView(dialog: dialog) { [weak self] result, _ in
            self?.finish(with: result == .cancel ? .abort : .continue, value: result)
        }
        installConfirmDialogContent(contentView, in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ConfirmDialogOptionController: AppDialogController<ConfirmDialogOptionResult> {
    init(dialog: ConfirmDialogState) {
        let panel = makeConfirmDialogPanel(initialHeight: 220)
        super.init(panel: panel)

        let contentView = ConfirmDialogView(dialog: dialog) { [weak self] action, isOptionEnabled in
            let result = ConfirmDialogOptionResult(action: action, isOptionEnabled: isOptionEnabled)
            self?.finish(with: action == .cancel ? .abort : .continue, value: result)
        }
        installConfirmDialogContent(contentView, in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
