import Foundation

extension AppModel {
    func upsertSSHProfile(_ profile: SSHConnectionProfile, password: String, keyPassphrase: String) {
        var sanitized = sanitizedSSHProfile(profile)
        sanitized.password = profile.credentialKind == .password ? password : nil
        sanitized.keyPassphrase = profile.credentialKind == .privateKey ? keyPassphrase : nil
        sanitized.updatedAt = Date()

        if let index = sshProfiles.firstIndex(where: { $0.id == sanitized.id }) {
            sshProfiles[index] = sanitized
        } else {
            sshProfiles.append(sanitized)
        }
        sshProfiles.sort { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        persist()
        statusMessage = String(localized: "ssh.profile.saved", defaultValue: "Saved SSH connection.", bundle: .module)
    }

    func deleteSSHProfile(_ profileID: UUID) {
        let previousCount = sshProfiles.count
        sshProfiles.removeAll { $0.id == profileID }
        guard sshProfiles.count != previousCount else {
            return
        }
        persist()
        statusMessage = String(localized: "ssh.profile.deleted", defaultValue: "Deleted SSH connection.", bundle: .module)
    }

    func connectSSHProfile(_ profileID: UUID) {
        guard let profile = sshProfiles.first(where: { $0.id == profileID }) else {
            statusMessage = String(localized: "ssh.profile.missing", defaultValue: "SSH connection not found.", bundle: .module)
            return
        }
        guard selectedProject != nil else {
            statusMessage = String(localized: "project.none_selected", defaultValue: "No project selected.", bundle: .module)
            return
        }

        let launch = SSHCommandBuilder.launchCommand(for: profile)
        guard let sessionID = createSplitTerminalRunningCommandInShell(command: launch.command, axis: .vertical, logCommand: launch.logCommand) else {
            statusMessage = String(localized: "workspace.split.create_failed", defaultValue: "Unable to create a new split pane.", bundle: .module)
            return
        }
        terminalFocusRequestID = sessionID
        statusMessage = String(
            format: String(localized: "ssh.profile.connecting_format", defaultValue: "Connecting to %@.", bundle: .module),
            profile.displayName
        )
    }

    func sshSecrets(for profileID: UUID) -> SSHCredentialSecrets {
        guard let profile = sshProfiles.first(where: { $0.id == profileID }) else {
            return SSHCredentialSecrets(password: "", keyPassphrase: "")
        }
        return SSHCredentialSecrets(
            password: profile.password ?? "",
            keyPassphrase: profile.keyPassphrase ?? ""
        )
    }

    private func sanitizedSSHProfile(_ profile: SSHConnectionProfile) -> SSHConnectionProfile {
        SSHConnectionProfile(
            id: profile.id,
            name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: profile.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(profile.port, 1), 65535),
            username: profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialKind: profile.credentialKind,
            privateKeyPath: profile.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: profile.updatedAt,
            password: profile.credentialKind == .password ? profile.password : nil,
            keyPassphrase: profile.credentialKind == .privateKey ? profile.keyPassphrase : nil
        )
    }
}

struct SSHCommandLaunch: Equatable {
    var command: String
    var logCommand: String
}

enum SSHCommandBuilder {
    static func launchCommand(for profile: SSHConnectionProfile) -> SSHCommandLaunch {
        let command = "codux-ssh \(shellQuoted(profile.id.uuidString))"
        return SSHCommandLaunch(command: command, logCommand: command)
    }
}
