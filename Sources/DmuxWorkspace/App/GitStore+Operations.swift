import Foundation

@MainActor
extension GitStore {
    func checkoutBranch(_ branch: String, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.checkout(branch: branch, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.branch.switch.success_format", bundle: .module), branch))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func checkoutRemoteBranch(_ remoteBranch: String, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                let localName = try service.checkoutRemoteBranch(remoteBranch, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.remote.branch.checkout_tracking_format", bundle: .module), localName))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func checkoutCommit(_ commit: GitCommitEntry, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.checkout(commit: commit.hash, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.history.checkout.success_format", bundle: .module), String(commit.hash.prefix(7))))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func revertCommit(_ commit: GitCommitEntry, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.revert(commit: commit.hash, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.history.revert.success_format", bundle: .module), String(commit.hash.prefix(7))))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func restoreCommit(_ commit: GitCommitEntry, forceRemote: Bool, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.resetCurrentBranch(to: commit.hash, at: path)
                if forceRemote {
                    try service.forcePush(at: path)
                }
                await MainActor.run {
                    onStatus(forceRemote ? String(localized: "git.history.restore.remote_success", bundle: .module) : String(localized: "git.history.restore.local_success", bundle: .module))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func createBranch(_ branchName: String, from commitHash: String? = nil, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                if let commitHash {
                    try service.createBranch(branchName, from: commitHash, at: path)
                } else {
                    try service.createBranch(branchName, at: path)
                }
                await MainActor.run {
                    onStatus(commitHash == nil
                        ? String(format: String(localized: "git.branch.create_and_switch.success_format", bundle: .module), branchName)
                        : String(format: String(localized: "git.branch.create_from_commit.success_format", bundle: .module), branchName))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func stageAll(project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.stageAll(at: path)
                await MainActor.run {
                    onStatus(String(localized: "git.files.stage_all.success", bundle: .module))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func unstageAll(project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.unstageAll(at: path)
                await MainActor.run {
                    onStatus(String(localized: "git.files.unstage_all.success", bundle: .module))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func stagePaths(_ paths: [String], project: Project, successMessage: String, onStatus: @escaping @MainActor (String) -> Void) {
        guard !paths.isEmpty else { return }
        beginPanelOperation()
        let repositoryPath = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.stage(paths, at: repositoryPath)
                await MainActor.run {
                    onStatus(successMessage)
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func unstagePaths(_ paths: [String], project: Project, successMessage: String, onStatus: @escaping @MainActor (String) -> Void) {
        guard !paths.isEmpty else { return }
        beginPanelOperation()
        let repositoryPath = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.unstage(paths, at: repositoryPath)
                await MainActor.run {
                    onStatus(successMessage)
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func discardEntries(_ entries: [GitFileEntry], project: Project, successMessage: String, onStatus: @escaping @MainActor (String) -> Void) {
        guard !entries.isEmpty else { return }
        beginPanelOperation()
        let repositoryPath = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.discard(entries, at: repositoryPath)
                await MainActor.run {
                    onStatus(successMessage)
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func discardEntry(_ entry: GitFileEntry, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let repositoryPath = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.discard(entry, at: repositoryPath)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.files.discard.success_format", bundle: .module), entry.path))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func commit(message: String, action: GitCommitAction, project: Project, onStatus: @escaping @MainActor (String) -> Void, onSuccess: @escaping @MainActor () -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.commit(message: message, at: path)
                switch action {
                case .commit:
                    break
                case .commitAndPush:
                    try service.push(at: path)
                case .commitAndSync:
                    try service.sync(at: path)
                }

                await MainActor.run {
                    onSuccess()
                    onStatus(action.successMessage)
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func amendLastCommitMessage(_ message: String, headCommitPushed: Bool, project: Project, onStatus: @escaping @MainActor (String) -> Void, onRewriteWarning: @escaping @MainActor () -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.amendLastCommitMessage(message, at: path)
                await MainActor.run {
                    onStatus(headCommitPushed
                        ? String(localized: "git.commit.edit_last_message.remote_success", bundle: .module)
                        : String(localized: "git.commit.edit_last_message.success", bundle: .module))
                    if headCommitPushed {
                        onRewriteWarning()
                    } else {
                        self.refresh(project: project, presentation: .preserveVisibleState)
                    }
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func undoLastCommit(headCommitPushed: Bool, project: Project, onStatus: @escaping @MainActor (String) -> Void, onRewriteWarning: @escaping @MainActor () -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.undoLastCommit(at: path)
                await MainActor.run {
                    onStatus(headCommitPushed
                        ? String(localized: "git.history.undo_last_commit.remote_success", bundle: .module)
                        : String(localized: "git.history.undo_last_commit.success", bundle: .module))
                    if headCommitPushed {
                        onRewriteWarning()
                    } else {
                        self.refresh(project: project, presentation: .preserveVisibleState)
                    }
                }
            } catch {
                await MainActor.run {
                    self.panelState.isGitLoading = false
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func addRemote(name: String, url: String, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.addRemote(name: name, url: url, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.remote.add.success_format", bundle: .module), name))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    onStatus(error.localizedDescription)
                }
            }
        }
    }

    func removeRemote(_ remote: GitRemoteEntry, project: Project, onStatus: @escaping @MainActor (String) -> Void) {
        beginPanelOperation()
        let path = project.path
        Task.detached {
            let service = GitService()
            do {
                try service.removeRemote(name: remote.name, at: path)
                await MainActor.run {
                    onStatus(String(format: String(localized: "git.remote.remove.success_format", bundle: .module), remote.name))
                    self.refresh(project: project, presentation: .preserveVisibleState)
                }
            } catch {
                await MainActor.run {
                    onStatus(error.localizedDescription)
                }
            }
        }
    }
}
