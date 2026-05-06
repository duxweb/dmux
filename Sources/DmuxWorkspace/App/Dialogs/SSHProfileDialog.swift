import AppKit
import SwiftUI

private final class SSHProfileDialogViewModel: ObservableObject {
    @Published var name: String
    @Published var host: String
    @Published var port: String
    @Published var username: String
    @Published var credentialKind: SSHCredentialKind
    @Published var privateKeyPath: String
    @Published var password: String
    @Published var keyPassphrase: String
    var onConfirm: ((SSHProfileDialogResult) -> Void)?
    var onCancel: (() -> Void)?
    var onChooseKey: (() -> Void)?

    let profileID: UUID

    init(dialog: SSHProfileDialogState) {
        profileID = dialog.profile.id
        name = dialog.profile.name
        host = dialog.profile.host
        port = "\(dialog.profile.port)"
        username = dialog.profile.username
        credentialKind = dialog.profile.credentialKind
        privateKeyPath = dialog.profile.privateKeyPath
        password = dialog.password
        keyPassphrase = dialog.keyPassphrase
    }
}

private struct SSHProfileDialogView: View {
    let dialog: SSHProfileDialogState
    @ObservedObject var viewModel: SSHProfileDialogViewModel
    @State private var hoveredField: String?

    private var header: AppDialogHeaderSpec {
        AppDialogHeaderSpec(title: dialog.title, message: dialog.message, icon: "server.rack", iconColor: AppTheme.focus)
    }

    private var parsedPort: Int {
        Int(viewModel.port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private var isConfirmDisabled: Bool {
        viewModel.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || parsedPort < 1
            || parsedPort > 65535
            || (viewModel.credentialKind == .password && viewModel.password.isEmpty)
            || (viewModel.credentialKind == .privateKey && viewModel.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        AppDialogFormLayout(
            header: header,
            width: 520,
            chromeTopInset: 8,
            contentSpacing: 12,
            headerTopPadding: 20,
            headerBottomPadding: 8,
            contentTopPadding: 8,
            contentBottomPadding: 16,
            footerTopPadding: 0,
            footerBottomPadding: 18
        ) {
            textField(
                title: String(localized: "ssh.profile.name", defaultValue: "Name", bundle: .module),
                text: $viewModel.name,
                placeholder: String(localized: "ssh.profile.name.placeholder", defaultValue: "Production Server", bundle: .module),
                key: "name"
            )
            HStack(spacing: 10) {
                textField(
                    title: String(localized: "ssh.profile.host", defaultValue: "Host", bundle: .module),
                    text: $viewModel.host,
                    placeholder: "example.com",
                    key: "host"
                )
                .frame(maxWidth: .infinity)
                textField(
                    title: String(localized: "ssh.profile.port", defaultValue: "Port", bundle: .module),
                    text: $viewModel.port,
                    placeholder: "22",
                    key: "port"
                )
                .frame(width: 92)
            }
            textField(
                title: String(localized: "ssh.profile.username", defaultValue: "Username", bundle: .module),
                text: $viewModel.username,
                placeholder: "root",
                key: "username"
            )

            Picker(String(localized: "ssh.profile.credential", defaultValue: "Credential", bundle: .module), selection: $viewModel.credentialKind) {
                Text(String(localized: "ssh.credential.none", defaultValue: "None / SSH Agent", bundle: .module)).tag(SSHCredentialKind.none)
                Text(String(localized: "ssh.credential.password", defaultValue: "Password", bundle: .module)).tag(SSHCredentialKind.password)
                Text(String(localized: "ssh.credential.private_key", defaultValue: "Private Key", bundle: .module)).tag(SSHCredentialKind.privateKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if viewModel.credentialKind == .password {
                secureField(
                    title: String(localized: "ssh.profile.password", defaultValue: "Password", bundle: .module),
                    text: $viewModel.password,
                    placeholder: String(localized: "ssh.profile.password.placeholder", defaultValue: "Stored locally", bundle: .module),
                    key: "password"
                )
            }

            if viewModel.credentialKind == .privateKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "ssh.profile.private_key", defaultValue: "Private Key", bundle: .module))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    HStack(spacing: 10) {
                        plainInput(text: $viewModel.privateKeyPath, placeholder: "~/.ssh/id_rsa", key: "key")
                        Button(String(localized: "common.choose", defaultValue: "Choose", bundle: .module)) {
                            viewModel.onChooseKey?()
                        }
                        .buttonStyle(AppDialogSecondaryButtonStyle())
                    }
                }
                secureField(
                    title: String(localized: "ssh.profile.key_passphrase", defaultValue: "Key Passphrase", bundle: .module),
                    text: $viewModel.keyPassphrase,
                    placeholder: String(localized: "ssh.profile.key_passphrase.placeholder", defaultValue: "Optional, stored locally", bundle: .module),
                    key: "passphrase"
                )
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)) { viewModel.onCancel?() }
                .buttonStyle(AppDialogSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button(dialog.confirmTitle) {
                submit()
            }
            .buttonStyle(AppDialogPrimaryButtonStyle())
            .disabled(isConfirmDisabled)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func submit() {
        let profile = SSHConnectionProfile(
            id: viewModel.profileID,
            name: viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: viewModel.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(parsedPort, 1), 65535),
            username: viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialKind: viewModel.credentialKind,
            privateKeyPath: viewModel.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: Date()
        )
        viewModel.onConfirm?(SSHProfileDialogResult(
            profile: profile,
            password: viewModel.password,
            keyPassphrase: viewModel.keyPassphrase
        ))
    }

    private func textField(title: String, text: Binding<String>, placeholder: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            plainInput(text: text, placeholder: placeholder, key: key)
        }
    }

    private func secureField(title: String, text: Binding<String>, placeholder: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .appInputSurface(isFocused: false, isHovered: hoveredField == key)
                .onHover { hoveredField = $0 ? key : nil }
        }
    }

    private func plainInput(text: Binding<String>, placeholder: String, key: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .appInputSurface(isFocused: false, isHovered: hoveredField == key)
            .onHover { hoveredField = $0 ? key : nil }
    }
}

final class SSHProfileDialogController: AppDialogController<SSHProfileDialogResult> {
    private let viewModel: SSHProfileDialogViewModel

    init(dialog: SSHProfileDialogState) {
        viewModel = SSHProfileDialogViewModel(dialog: dialog)
        let panel = AppDialogPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
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

        super.init(panel: panel)

        let contentView = SSHProfileDialogView(dialog: dialog, viewModel: viewModel)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 1)
        hostingController.view.autoresizingMask = [.width, .height]
        hostingController.view.layoutSubtreeIfNeeded()
        let contentHeight = max(1, hostingController.view.fittingSize.height)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 520, height: contentHeight))
        panel.minSize = NSSize(width: 520, height: contentHeight)
        panel.maxSize = NSSize(width: 520, height: contentHeight)
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
        viewModel.onChooseKey = { [weak self] in
            guard let self, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.title = String(localized: "ssh.profile.choose_key.title", defaultValue: "Choose Private Key", bundle: .module)
            panel.prompt = String(localized: "common.choose", defaultValue: "Choose", bundle: .module)
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.viewModel.privateKeyPath = url.path
            }
        }
    }
}
