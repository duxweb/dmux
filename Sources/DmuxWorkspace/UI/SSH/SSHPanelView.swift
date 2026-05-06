import SwiftUI

struct SSHPanelView: View {
    let model: AppModel

    private var sortedProfiles: [SSHConnectionProfile] {
        model.sshProfiles.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GitPanelSeparator()
            content
        }
        .background(Color.clear)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "ssh.panel.title", defaultValue: "SSH", bundle: .module))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(localized: "ssh.panel.subtitle", defaultValue: "Global Connections", bundle: .module))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                presentProfileDialog()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(GitToolbarIconButtonStyle())
            .help(String(localized: "ssh.profile.add", defaultValue: "Add SSH Connection", bundle: .module))

            Button {
                model.toggleRightPanel(.ssh)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GitToolbarIconButtonStyle())
            .help(String(localized: "common.close", defaultValue: "Close", bundle: .module))
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder
    private var content: some View {
        if sortedProfiles.isEmpty {
            SSHPanelEmptyView {
                presentProfileDialog()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedProfiles) { profile in
                        SSHProfileRow(
                            model: model,
                            profile: profile,
                            onConnect: { model.connectSSHProfile(profile.id) },
                            onEdit: { presentProfileDialog(profile: profile) },
                            onDelete: { confirmDelete(profile) }
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    private func presentProfileDialog(profile: SSHConnectionProfile? = nil) {
        guard let parentWindow = model.presentationWindow() else {
            return
        }
        let profile = profile ?? SSHConnectionProfile(
            id: UUID(),
            name: "",
            host: "",
            port: 22,
            username: NSUserName(),
            credentialKind: .none,
            privateKeyPath: "",
            updatedAt: Date()
        )
        let secrets = model.sshSecrets(for: profile.id)
        let isEditing = model.sshProfiles.contains { $0.id == profile.id }
        let dialog = SSHProfileDialogState(
            title: isEditing
                ? String(localized: "ssh.profile.edit", defaultValue: "Edit SSH Connection", bundle: .module)
                : String(localized: "ssh.profile.add", defaultValue: "Add SSH Connection", bundle: .module),
            message: String(localized: "ssh.profile.dialog.message", defaultValue: "Saved credentials are kept in Codux local app data.", bundle: .module),
            confirmTitle: String(localized: "common.save", defaultValue: "Save", bundle: .module),
            profile: profile,
            password: secrets.password,
            keyPassphrase: secrets.keyPassphrase
        )
        SSHProfileDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { result in
            guard let result else { return }
            model.upsertSSHProfile(result.profile, password: result.password, keyPassphrase: result.keyPassphrase)
        }
    }

    private func confirmDelete(_ profile: SSHConnectionProfile) {
        guard let parentWindow = model.presentationWindow() else {
            return
        }
        let dialog = ConfirmDialogState(
            title: String(localized: "ssh.profile.delete", defaultValue: "Delete SSH Connection", bundle: .module),
            message: String(
                format: String(localized: "ssh.profile.delete.message_format", defaultValue: "Delete %@? The saved local credential will also be removed.", bundle: .module),
                profile.displayName
            ),
            icon: "trash",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.delete", defaultValue: "Delete", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { result in
            guard result == .primary else { return }
            model.deleteSSHProfile(profile.id)
        }
    }
}

private struct SSHProfileRow: View {
    let model: AppModel
    let profile: SSHConnectionProfile
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(credentialTint.opacity(0.16))
                Image(systemName: credentialIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(credentialTint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(endpoint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button(action: onConnect) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GitHeaderIconButtonStyle())
                .help(String(localized: "ssh.profile.connect", defaultValue: "Connect", bundle: .module))
                .disabled(model.selectedProject == nil)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GitHeaderIconButtonStyle())
                .help(String(localized: "ssh.profile.edit", defaultValue: "Edit SSH Connection", bundle: .module))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GitHeaderIconButtonStyle())
                .help(String(localized: "common.delete", defaultValue: "Delete", bundle: .module))
            }
            .opacity(isHovered ? 1 : 0.72)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? AppTheme.panel.opacity(0.9) : AppTheme.panel.opacity(0.68))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator.opacity(isHovered ? 0.5 : 0.28), lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onConnect)
        .contextMenu {
            Button(action: onConnect) {
                Label(String(localized: "ssh.profile.connect", defaultValue: "Connect", bundle: .module), systemImage: "terminal")
            }
            .disabled(model.selectedProject == nil)
            Button(action: onEdit) {
                Label(String(localized: "ssh.profile.edit", defaultValue: "Edit SSH Connection", bundle: .module), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(String(localized: "common.delete", defaultValue: "Delete", bundle: .module), systemImage: "trash")
            }
        }
    }

    private var endpoint: String {
        "\(profile.username)@\(profile.host):\(profile.port)"
    }

    private var credentialIcon: String {
        switch profile.credentialKind {
        case .none:
            "person.badge.key"
        case .password:
            "lock.fill"
        case .privateKey:
            "key.fill"
        }
    }

    private var credentialTint: Color {
        switch profile.credentialKind {
        case .none:
            AppTheme.textSecondary
        case .password:
            AppTheme.warning
        case .privateKey:
            AppTheme.focus
        }
    }
}

private struct SSHPanelEmptyView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.textMuted)

            VStack(spacing: 5) {
                Text(String(localized: "ssh.panel.empty.title", defaultValue: "No SSH Connections", bundle: .module))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(localized: "ssh.panel.empty.help", defaultValue: "Add a global SSH profile and double-click it to connect in a terminal.", bundle: .module))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 220)
            }

            Button {
                onAdd()
            } label: {
                Label(String(localized: "ssh.profile.add", defaultValue: "Add SSH Connection", bundle: .module), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(24)
    }
}
