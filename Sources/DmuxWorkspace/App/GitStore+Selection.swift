import Foundation

@MainActor
extension GitStore {
    func updateRemoteOperation(_ operation: GitRemoteOperation?) {
        panelState.activeGitRemoteOperation = operation
    }

    func updateSelectionState(entry: GitFileEntry?, entryIDs: Set<String>, commitHash: String?, anchorID: String?) {
        panelState.selectedGitEntry = entry
        panelState.selectedGitEntryIDs = entryIDs
        panelState.selectedGitCommitHash = commitHash
        panelState.gitSelectionAnchorID = anchorID
    }

    func isEntrySelected(_ entry: GitFileEntry) -> Bool {
        panelState.selectedGitEntryIDs.contains(entry.id)
    }

    func toggleEntrySelection(_ entry: GitFileEntry) {
        if panelState.selectedGitEntryIDs.contains(entry.id) {
            panelState.selectedGitEntryIDs.remove(entry.id)
        } else {
            panelState.selectedGitEntryIDs.insert(entry.id)
        }
        panelState.selectedGitEntry = entry
        panelState.gitSelectionAnchorID = entry.id
    }

    func selectEntry(_ entry: GitFileEntry, in gitState: GitRepositoryState?, extendingRange: Bool) {
        guard let gitState else {
            panelState.selectedGitEntry = entry
            panelState.selectedGitEntryIDs = [entry.id]
            panelState.gitSelectionAnchorID = entry.id
            return
        }

        panelState.selectedGitEntry = entry
        let allEntries = gitState.staged + gitState.changes + gitState.untracked
        if extendingRange,
           let anchorID = panelState.gitSelectionAnchorID,
           let anchorIndex = allEntries.firstIndex(where: { $0.id == anchorID }),
           let targetIndex = allEntries.firstIndex(where: { $0.id == entry.id }) {
            let lower = min(anchorIndex, targetIndex)
            let upper = max(anchorIndex, targetIndex)
            panelState.selectedGitEntryIDs = Set(allEntries[lower...upper].map(\.id))
        } else {
            panelState.selectedGitEntryIDs = [entry.id]
            panelState.gitSelectionAnchorID = entry.id
        }
    }

    func prepareEntryContextMenu(_ entry: GitFileEntry) {
        panelState.selectedGitEntry = entry
        panelState.gitSelectionAnchorID = entry.id
    }

    func selectCommit(_ commit: GitCommitEntry) {
        panelState.selectedGitCommitHash = commit.hash
    }

    func updateDiffState(text: String, isLoading: Bool) {
        panelState.gitDiffText = text
        panelState.isGitDiffLoading = isLoading
    }

    func loadDiff(for entry: GitFileEntry, project: Project?) {
        guard let project else {
            return
        }

        panelState.selectedGitEntry = entry
        let projectID = project.id
        let path = project.path
        panelState.isGitDiffLoading = true
        panelState.gitDiffText = String(localized: "git.diff.loading", defaultValue: "Loading diff...", bundle: .module)

        Task.detached {
            let service = GitService()
            do {
                let diff = try service.diff(for: entry, at: path)
                await MainActor.run {
                    guard self.panelState.selectedGitEntry?.id == entry.id else { return }
                    self.panelState.gitDiffText = diff
                    self.panelState.isGitDiffLoading = false
                    self.cacheState(for: projectID)
                }
            } catch {
                await MainActor.run {
                    guard self.panelState.selectedGitEntry?.id == entry.id else { return }
                    self.panelState.gitDiffText = error.localizedDescription
                    self.panelState.isGitDiffLoading = false
                    self.cacheState(for: projectID)
                }
            }
        }
    }
}
