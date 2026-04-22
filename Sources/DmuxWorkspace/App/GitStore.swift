import CoreServices
import Foundation
import Observation

enum GitRepositoryWatchFilter {
    static func shouldForward(repositoryPath: String, path: String, flags: FSEventStreamEventFlags) -> Bool {
        let ignoredFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagHistoryDone
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        if (flags & ignoredFlags) != 0 {
            return false
        }

        let normalizedRepositoryPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let gitDirectoryPath = normalizedRepositoryPath + "/.git"

        guard normalizedPath == gitDirectoryPath || normalizedPath.hasPrefix(gitDirectoryPath + "/") else {
            return true
        }

        let allowedGitMetadataPrefixes = [
            gitDirectoryPath + "/HEAD",
            gitDirectoryPath + "/index",
            gitDirectoryPath + "/refs/",
            gitDirectoryPath + "/logs/HEAD",
            gitDirectoryPath + "/FETCH_HEAD",
            gitDirectoryPath + "/ORIG_HEAD",
            gitDirectoryPath + "/packed-refs",
        ]

        return allowedGitMetadataPrefixes.contains { prefix in
            normalizedPath == prefix || normalizedPath.hasPrefix(prefix)
        }
    }
}

final class GitRepositoryWatcher {
    private let repositoryPath: String
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init?(repositoryPath: String, onChange: @escaping ([String]) -> Void) {
        self.repositoryPath = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, eventCount, eventPathsPointer, eventFlagsPointer, _ in
                guard let info else {
                    return
                }

                let watcher = Unmanaged<GitRepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let eventPaths = unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String] ?? []
                let eventFlags = Array(UnsafeBufferPointer(start: eventFlagsPointer, count: eventCount))
                watcher.handle(paths: eventPaths, flags: eventFlags)
            },
            &context,
            [self.repositoryPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            invalidate()
            return nil
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let interestingPaths = zip(paths, flags).compactMap { path, flags -> String? in
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard shouldForward(path: normalizedPath, flags: flags) else {
                return nil
            }
            return normalizedPath
        }

        guard !interestingPaths.isEmpty else {
            return
        }
        onChange(interestingPaths)
    }

    private func shouldForward(path: String, flags: FSEventStreamEventFlags) -> Bool {
        GitRepositoryWatchFilter.shouldForward(
            repositoryPath: repositoryPath,
            path: path,
            flags: flags
        )
    }
}

@MainActor
@Observable
final class GitStore {
    enum RefreshPresentation {
        case fullScreen
        case preserveVisibleState
    }

    struct CachedGitPanelEntry {
        var projectID: UUID
        var state: GitPanelState
        var updatedAt: Date
    }

    var panelState = GitPanelState.empty

    var cachedPanels = RecentProjectCache<CachedGitPanelEntry>()
    var remoteSyncTimer: Timer?
    var remoteSyncInterval: TimeInterval = 60
    var selectedProjectProvider: (@MainActor () -> Project?)?
    var remoteSyncEnabledProvider: (@MainActor () -> Bool)?
    var statusAutoRefreshSelectedProjectProvider: (@MainActor () -> Project?)?
    var statusAutoRefreshEnabledProvider: (@MainActor () -> Bool)?
    var repositoryWatcher: GitRepositoryWatcher?
    var watchedRepositoryProjectID: UUID?
    var watchedRepositoryPath: String?
    var pendingAutomaticRefreshTask: Task<Void, Never>?
    var isAutomaticRefreshInFlight = false
}
