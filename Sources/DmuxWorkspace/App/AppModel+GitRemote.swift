import AppKit
import Foundation

extension AppModel {
    func cloneGitRepository() {
        guard let project = selectedProject else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        let dialog = GitInputDialogState(
            kind: .cloneRepository,
            title: String(localized: "git.empty.clone_remote_repository", defaultValue: "Clone Remote Repository", bundle: .module),
            message: String(localized: "git.clone.message", defaultValue: "Enter a remote repository URL to clone it into the current project directory.", bundle: .module),
            placeholder: "https://github.com/foo/bar.git",
            confirmTitle: String(localized: "git.clone.start", defaultValue: "Start Clone", bundle: .module),
            value: "",
            isMultiline: false
        )
        GitInputPanelPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] value in
            guard let self, let value else { return }
            let remoteURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteURL.isEmpty else {
                self.statusMessage = String(localized: "git.remote.url_required", defaultValue: "Please enter a remote repository URL.", bundle: .module)
                return
            }

            let savedCredential = self.gitCredentialStore.credential(for: remoteURL)
            self.gitStore.cloneRepository(project: project, remoteURL: remoteURL, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
                self.promptForGitCredential(completion: completion)
            }, onAuthSucceeded: { credential in
                self.gitCredentialStore.save(credential, for: remoteURL)
            })
        }
    }

    func pullGitBranch() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.pull, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func fetchGitBranch() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.fetch, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func refreshRemoteBranches() {
        guard let project = selectedProject else { return }
        gitStore.refreshRemoteBranches(project: project) { self.statusMessage = $0 }
    }

    func addGitRemote() {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        guard let project = selectedProject else { return }

        let nameDialog = GitInputDialogState(
            kind: .cloneRepository,
            title: String(localized: "git.remote.add", defaultValue: "Add Remote", bundle: .module),
            message: String(localized: "git.remote.add.name_message", defaultValue: "Enter the remote name first, such as origin or upstream.", bundle: .module),
            placeholder: String(localized: "git.remote.name", defaultValue: "Remote Name", bundle: .module),
            confirmTitle: String(localized: "common.next", defaultValue: "Next", bundle: .module),
            value: "",
            isMultiline: false
        )

        GitInputPanelPresenter.present(dialog: nameDialog, parentWindow: parentWindow) { [weak self] nameValue in
            guard let self else { return }
            let name = nameValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }

            let urlDialog = GitInputDialogState(
                kind: .cloneRepository,
                title: String(localized: "git.remote.add", defaultValue: "Add Remote", bundle: .module),
                message: String(localized: "git.remote.add.url_message", defaultValue: "Enter the remote URL.", bundle: .module),
                placeholder: "https://github.com/org/repo.git",
                confirmTitle: String(localized: "common.add", defaultValue: "Add", bundle: .module),
                value: "",
                isMultiline: false
            )

            GitInputPanelPresenter.present(dialog: urlDialog, parentWindow: parentWindow) { urlValue in
                let url = urlValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !url.isEmpty else { return }
                self.gitStore.addRemote(name: name, url: url, project: project) { self.statusMessage = $0 }
            }
        }
    }

    func removeGitRemote(_ remote: GitRemoteEntry) {
        guard let project = selectedProject else { return }
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        let dialog = ConfirmDialogState(
            title: String(localized: "git.remote.remove", defaultValue: "Remove Remote", bundle: .module),
            message: String(format: String(localized: "git.remote.remove.confirm_format", defaultValue: "Are you sure you want to remove remote %@?", bundle: .module), remote.name),
            icon: "trash",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "common.remove", defaultValue: "Remove", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            if project.gitDefaultPushRemoteName == remote.name,
               let index = self.projects.firstIndex(where: { $0.id == project.id }) {
                self.projects[index].gitDefaultPushRemoteName = nil
                self.persist()
            }
            self.gitStore.removeRemote(remote, project: project) { self.statusMessage = $0 }
        }
    }

    func setDefaultPushRemote(_ remote: GitRemoteEntry) {
        guard let project = selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].gitDefaultPushRemoteName = remote.name
        persist()
        statusMessage = String(format: String(localized: "git.remote.default_push.set_format", defaultValue: "Set %@ as the default push remote.", bundle: .module), remote.name)
    }

    func clearDefaultPushRemote() {
        guard let project = selectedProject,
              let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].gitDefaultPushRemoteName = nil
        persist()
        statusMessage = String(localized: "git.remote.default_push.cleared", defaultValue: "Restored the Git default push target.", bundle: .module)
    }

    func pushGitBranch() {
        guard let project = selectedProject else { return }

        if let defaultRemote = defaultPushRemote(for: project) {
            pushGitBranch(to: defaultRemote)
            return
        }

        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.push, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func pushGitBranch(_ branch: String? = nil, to remote: GitRemoteEntry) {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForRemote(remote)
        let branchName = branch ?? gitState?.branch ?? "HEAD"
        gitStore.pushBranch(branchName, to: remote, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
            self.promptForGitCredential(completion: completion)
        }, onAuthSucceeded: { credential in
            self.gitCredentialStore.save(credential, for: remote.url)
        })
    }

    func pushCurrentLocalBranch(to remoteBranch: String) {
        guard let project = selectedProject,
              let localBranch = gitState?.branch else { return }

        let parts = remoteBranch.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2,
              let remote = gitRemotes.first(where: { $0.name == parts[0] }) else {
            statusMessage = String(localized: "git.remote.matching_not_found", defaultValue: "Matching remote was not found.", bundle: .module)
            return
        }

        let savedCredential = credentialForRemote(remote)
        gitStore.pushLocalBranch(localBranch, to: remote, remoteBranch: parts[1], project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in
            self.promptForGitCredential(completion: completion)
        }, onAuthSucceeded: { credential in
            self.gitCredentialStore.save(credential, for: remote.url)
        })
    }

    func forcePushGitBranch() {
        guard let project = selectedProject else { return }
        let dialog = ConfirmDialogState(
            title: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module),
            message: String(localized: "git.remote.force_push.message", defaultValue: "Overwrite the current remote branch. Only use this when you intentionally want to rewrite remote history.", bundle: .module),
            icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module),
            primaryTint: AppTheme.warning,
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }
        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self, result == .primary else { return }
            let savedCredential = self.credentialForSelectedProjectRemote()
            self.gitStore.performRemoteAction(GitRemoteAction.forcePush, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
                if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                    self.gitCredentialStore.save(credential, for: remoteURL)
                }
            }, onConflict: {
                self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
            })
        }
    }

    func syncGitRemote() {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.sync, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: project.path)
        })
    }

    func promptForGitCredential(completion: @escaping (GitCredential?) -> Void) {
        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            completion(nil)
            return
        }

        let dialog = GitCredentialDialogState(
            title: String(localized: "git.credentials.title", defaultValue: "Git Credentials Required", bundle: .module),
            message: String(localized: "git.credentials.message", defaultValue: "Remote access requires authentication. Enter your username and password or token to retry.", bundle: .module),
            confirmTitle: String(localized: "common.continue", defaultValue: "Continue", bundle: .module),
            cancelTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        )

        GitCredentialDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] credential in
            guard let self else {
                completion(nil)
                return
            }
            guard let credential else {
                self.statusMessage = String(localized: "git.auth.cancelled", defaultValue: "Git authentication was cancelled.", bundle: .module)
                completion(nil)
                return
            }

            guard !credential.username.isEmpty, !credential.password.isEmpty else {
                self.statusMessage = String(localized: "git.auth.credentials_required", defaultValue: "Username and password or token cannot be empty.", bundle: .module)
                completion(nil)
                return
            }

            completion(credential)
        }
    }

    func credentialForSelectedProjectRemote() -> GitCredential? {
        guard let project = selectedProject,
              let remoteURL = try? gitService.originURL(at: project.path),
              !remoteURL.isEmpty else {
            return nil
        }
        return gitCredentialStore.credential(for: remoteURL)
    }

    private func defaultPushRemote(for project: Project) -> GitRemoteEntry? {
        guard let name = project.gitDefaultPushRemoteName else { return nil }
        return gitRemotes.first(where: { $0.name == name })
    }

    private func credentialForRemote(_ remote: GitRemoteEntry) -> GitCredential? {
        gitCredentialStore.credential(for: remote.url)
    }

    func presentRemoteSyncConflictAlert(repositoryPath: String) {
        let dialog = ConfirmDialogState(
            title: String(localized: "git.sync.conflict.title", defaultValue: "Sync Conflict", bundle: .module),
            message: String(localized: "git.sync.conflict.message", defaultValue: "A conflict occurred while pulling. You can resolve it manually first, or force push the current branch directly.", bundle: .module),
            icon: "exclamationmark.triangle.fill",
            iconColor: AppTheme.warning,
            primaryTitle: String(localized: "git.sync.conflict.resolve_manually", defaultValue: "Resolve Manually", bundle: .module),
            secondaryTitle: String(localized: "git.remote.force_push", defaultValue: "Force Push", bundle: .module)
        )

        guard let parentWindow = presentationWindow() else {
            statusMessage = String(localized: "app.window.main_missing", defaultValue: "Unable to find the main window.", bundle: .module)
            return
        }

        ConfirmDialogPresenter.present(dialog: dialog, parentWindow: parentWindow) { [weak self] result in
            guard let self else { return }
            if result == .secondary {
                self.forcePushAfterConflict(at: repositoryPath)
            } else {
                self.statusMessage = String(localized: "git.remote.pull_conflicts", defaultValue: "Pull resulted in conflicts. Resolve them manually first.", bundle: .module)
                self.refreshGitState()
            }
        }
    }

    private func forcePushAfterConflict(at path: String) {
        guard let project = selectedProject else { return }
        let savedCredential = credentialForSelectedProjectRemote()
        gitStore.performRemoteAction(GitRemoteAction.forcePush, project: project, credential: savedCredential, onStatus: { self.statusMessage = $0 }, onAuthRequired: { completion in self.promptForGitCredential(completion: completion) }, onAuthSucceeded: { credential in
            if let remoteURL = try? self.gitService.originURL(at: project.path), !remoteURL.isEmpty {
                self.gitCredentialStore.save(credential, for: remoteURL)
            }
        }, onConflict: {
            self.presentRemoteSyncConflictAlert(repositoryPath: path)
        })
    }
}
