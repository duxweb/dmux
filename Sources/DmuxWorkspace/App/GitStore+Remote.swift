import Foundation

@MainActor
extension GitStore {
    func refreshRemoteBranches(project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        let path = project.path
        let projectID = project.id
        panelState.activeGitRemoteOperation = .fetch
        let startedAt = Date()

        Task.detached {
            let service = GitService()
            do {
                try service.fetch(at: path)
                let branches = try service.localBranches(at: path)
                let remoteBranches = try service.remoteBranches(at: path)
                let remotes = try service.remotes(at: path)
                let remoteState = try service.remoteSyncState(at: path)
                let remainingDelay = max(0, 1.2 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    self.panelState.activeGitRemoteOperation = nil
                    self.panelState.gitBranches = branches
                    self.panelState.gitRemoteBranches = remoteBranches
                    self.panelState.gitRemotes = remotes
                    self.panelState.gitRemoteSyncState = remoteState
                    self.cacheState(for: projectID)
                    onStatus(String(localized: "git.remote.branches.refresh_success", bundle: .module))
                }
            } catch {
                let remainingDelay = max(0, 1.2 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func pushBranch(_ branch: String, to remote: GitRemoteEntry, project: Project, credential: GitCredential? = nil, onStatus: @escaping @MainActor (String) -> Void, onAuthRequired: @escaping @MainActor (@escaping (GitCredential?) -> Void) -> Void, onAuthSucceeded: @escaping @MainActor (GitCredential) -> Void) {
        panelState.activeGitRemoteOperation = .push
        let startedAt = Date()
        let path = project.path

        Task.detached {
            let service = GitService()
            do {
                try service.push(branch: branch, to: remote.name, at: path, credential: credential)
                let remainingDelay = max(0, 1.0 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if let credential {
                        onAuthSucceeded(credential)
                    }
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(String(format: String(localized: "git.remote.push.success_format", bundle: .module), remote.name))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                let remainingDelay = max(0, 1.0 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if case GitServiceError.authenticationRequired = error,
                       credential == nil {
                        onAuthRequired { credential in
                            guard let credential else {
                                self.panelState.activeGitRemoteOperation = nil
                                onStatus(String(localized: "git.auth.cancelled", bundle: .module))
                                return
                            }
                            self.pushBranch(branch, to: remote, project: project, credential: credential, onStatus: onStatus, onAuthRequired: onAuthRequired, onAuthSucceeded: onAuthSucceeded)
                        }
                        return
                    }
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func pushLocalBranch(_ localBranch: String, to remote: GitRemoteEntry, remoteBranch: String, project: Project, credential: GitCredential? = nil, onStatus: @escaping @MainActor (String) -> Void, onAuthRequired: @escaping @MainActor (@escaping (GitCredential?) -> Void) -> Void, onAuthSucceeded: @escaping @MainActor (GitCredential) -> Void) {
        panelState.activeGitRemoteOperation = .push
        let startedAt = Date()
        let path = project.path

        Task.detached {
            let service = GitService()
            do {
                try service.push(localBranch: localBranch, to: remote.name, remoteBranch: remoteBranch, at: path, credential: credential)
                let remainingDelay = max(0, 1.0 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if let credential {
                        onAuthSucceeded(credential)
                    }
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(String(format: String(localized: "git.remote.push.branch_success_format", bundle: .module), localBranch, remote.name, remoteBranch))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                let remainingDelay = max(0, 1.0 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if case GitServiceError.authenticationRequired = error,
                       credential == nil {
                        onAuthRequired { credential in
                            guard let credential else {
                                self.panelState.activeGitRemoteOperation = nil
                                onStatus(String(localized: "git.auth.cancelled", bundle: .module))
                                return
                            }
                            self.pushLocalBranch(localBranch, to: remote, remoteBranch: remoteBranch, project: project, credential: credential, onStatus: onStatus, onAuthRequired: onAuthRequired, onAuthSucceeded: onAuthSucceeded)
                        }
                        return
                    }
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func performRemoteAction(_ action: GitRemoteAction, project: Project, credential: GitCredential? = nil, onStatus: @escaping @MainActor (String) -> Void, onAuthRequired: @escaping @MainActor (@escaping (GitCredential?) -> Void) -> Void, onAuthSucceeded: @escaping @MainActor (GitCredential) -> Void, onConflict: @escaping @MainActor () -> Void) {
        panelState.activeGitRemoteOperation = remoteOperation(for: action)
        let startedAt = Date()
        let path = project.path

        Task.detached {
            let service = GitService()
            do {
                let message = try Self.runRemoteAction(action, service: service, path: path, credential: credential)
                let remainingDelay = max(0, 1.2 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if let credential {
                        onAuthSucceeded(credential)
                    }
                    self.panelState.activeGitRemoteOperation = nil
                    onStatus(message)
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                let remainingDelay = max(0, 1.2 - Date().timeIntervalSince(startedAt))
                if remainingDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                }
                await MainActor.run {
                    if case GitServiceError.authenticationRequired = error,
                       credential == nil {
                        onAuthRequired { credential in
                            guard let credential else {
                                self.panelState.activeGitRemoteOperation = nil
                                onStatus(String(localized: "git.auth.cancelled", bundle: .module))
                                return
                            }
                            self.performRemoteAction(action, project: project, credential: credential, onStatus: onStatus, onAuthRequired: onAuthRequired, onAuthSucceeded: onAuthSucceeded, onConflict: onConflict)
                        }
                        return
                    }
                    if Self.looksLikeConflict(error.localizedDescription), action == .sync {
                        self.panelState.activeGitRemoteOperation = nil
                        onConflict()
                    } else {
                        self.panelState.activeGitRemoteOperation = nil
                        onStatus(error.localizedDescription)
                    }
                }
            }
        }
    }

    private static func looksLikeConflict(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("conflict")
            || normalized.contains("merge conflict")
            || normalized.contains("could not apply")
            || normalized.contains("resolve all conflicts")
    }

    private nonisolated static func runRemoteAction(_ action: GitRemoteAction, service: GitService, path: String, credential: GitCredential?) throws -> String {
        switch action {
        case .fetch:
            try service.fetch(at: path, credential: credential)
            return String(localized: "git.remote.fetch.success", defaultValue: "Fetched remote updates.", bundle: .module)
        case .pull:
            try service.pull(at: path, credential: credential)
            return String(localized: "git.remote.pull.success", defaultValue: "Pulled remote updates.", bundle: .module)
        case .push:
            try service.push(at: path, credential: credential)
            return String(localized: "git.remote.push.current_success", defaultValue: "Pushed the current branch.", bundle: .module)
        case .forcePush:
            try service.forcePush(at: path, credential: credential)
            return String(localized: "git.remote.force_push.current_success", defaultValue: "Force pushed the current branch.", bundle: .module)
        case .sync:
            try service.fetch(at: path, credential: credential)
            let remoteState = try service.remoteSyncState(at: path)
            if remoteState.incomingCount > 0 {
                try service.pull(at: path, credential: credential)
            }
            let postPullState = try service.remoteSyncState(at: path)
            if postPullState.outgoingCount > 0 {
                try service.push(at: path, credential: credential)
            }
            if remoteState.incomingCount > 0 && postPullState.outgoingCount > 0 {
                return String(
                    format: String(localized: "git.remote.sync.pull_push_format", defaultValue: "Pulled %@ updates and pushed %@ commits.", bundle: .module),
                    "\(remoteState.incomingCount)",
                    "\(postPullState.outgoingCount > 0 ? postPullState.outgoingCount : remoteState.outgoingCount)"
                )
            }
            if remoteState.incomingCount > 0 {
                return String(format: String(localized: "git.remote.sync.pull_only_format", defaultValue: "Pulled %@ updates.", bundle: .module), "\(remoteState.incomingCount)")
            }
            if postPullState.outgoingCount > 0 || remoteState.outgoingCount > 0 {
                return String(format: String(localized: "git.remote.sync.push_only_format", defaultValue: "Pushed %@ commits.", bundle: .module), "\(postPullState.outgoingCount > 0 ? postPullState.outgoingCount : remoteState.outgoingCount)")
            }
            return String(localized: "git.remote.sync.synced", defaultValue: "Remote is synced.", bundle: .module)
        }
    }

    private nonisolated func remoteOperation(for action: GitRemoteAction) -> GitRemoteOperation? {
        switch action {
        case .fetch:
            return .fetch
        case .pull:
            return .pull
        case .push:
            return .push
        case .forcePush:
            return .forcePush
        case .sync:
            return nil
        }
    }
}
