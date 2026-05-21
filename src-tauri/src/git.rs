use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Deserialize;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tauri::AppHandle;

const REVIEW_UNTRACKED_LINE_COUNT_LIMIT_BYTES: u64 = 2 * 1024 * 1024;
const GIT_WATCH_DEBOUNCE_MS: u64 = 250;
static GIT_COMMAND_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

type GitRepository = git2::Repository;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatusSnapshot {
    pub branch: String,
    pub upstream: Option<String>,
    pub ahead: i64,
    pub behind: i64,
    pub staged: Vec<GitFileStatus>,
    pub unstaged: Vec<GitFileStatus>,
    pub untracked: Vec<GitFileStatus>,
    pub commits: Vec<GitCommitSummary>,
    pub branches: Vec<GitBranchSummary>,
    pub remote_branches: Vec<String>,
    pub remotes: Vec<GitRemoteSummary>,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBriefStatus {
    pub branch: String,
    pub ahead: i64,
    pub behind: i64,
    pub changes: usize,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitFileStatus {
    pub path: String,
    pub index_status: String,
    pub worktree_status: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitSummary {
    pub hash: String,
    pub title: String,
    pub relative_time: String,
    pub decorations: Option<String>,
    pub graph_prefix: String,
    pub author: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitRemoteSummary {
    pub name: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReviewSnapshot {
    pub mode: String,
    pub title: String,
    pub base_branch: Option<String>,
    pub diff_stat: String,
    pub files: Vec<GitReviewFile>,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReviewFile {
    pub path: String,
    pub status: String,
    pub additions: i64,
    pub deletions: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchesSnapshot {
    pub current: String,
    pub local: Vec<GitBranchSummary>,
    pub remote: Vec<GitBranchSummary>,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchSummary {
    pub name: String,
    pub upstream: Option<String>,
    pub hash: String,
    pub is_current: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffSnapshot {
    pub path: String,
    pub diff: String,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReviewContentSnapshot {
    pub path: String,
    pub head_content: String,
    pub base_content: Option<String>,
    pub index_content: Option<String>,
    pub worktree_content: String,
    pub added_lines: Vec<i64>,
    pub deleted_lines: Vec<i64>,
    pub is_repository: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPathsRequest {
    pub project_path: String,
    pub paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitRequest {
    pub project_path: String,
    pub message: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBranchRequest {
    pub project_path: String,
    pub branch: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCreateBranchRequest {
    pub project_path: String,
    pub branch: String,
    pub checkout: bool,
    pub from: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffRequest {
    pub project_path: String,
    pub path: String,
    pub staged: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReviewDiffRequest {
    pub project_path: String,
    pub path: String,
    pub base_branch: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReviewContentRequest {
    pub project_path: String,
    pub path: String,
    pub base_branch: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCloneRequest {
    pub project_path: String,
    pub remote_url: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitActionRequest {
    pub project_path: String,
    pub message: String,
    pub action: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitRemoteRequest {
    pub project_path: String,
    pub name: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDeleteBranchRequest {
    pub project_path: String,
    pub branch: String,
    pub force: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitRefRequest {
    pub project_path: String,
    pub commit: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitRestoreCommitRequest {
    pub project_path: String,
    pub commit: String,
    pub force_remote: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRemoteRequest {
    pub project_path: String,
    pub remote: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPushRemoteBranchRequest {
    pub project_path: String,
    pub local_branch: Option<String>,
    pub remote_branch: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitWatchRegistration {
    pub project_path: String,
    pub repository_path: String,
    pub is_repository: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitRepositoryChangeEvent {
    pub project_path: String,
    pub repository_path: String,
    pub changed_paths: Vec<String>,
}

pub struct GitWatchManager {
    watchers: Mutex<HashMap<String, GitRepositoryWatcher>>,
}

struct GitRepositoryWatcher {
    _watcher: RecommendedWatcher,
    project_paths: Arc<Mutex<HashSet<String>>>,
    _repository_path: String,
    _watch_paths: Vec<PathBuf>,
}

impl Default for GitWatchManager {
    fn default() -> Self {
        Self {
            watchers: Mutex::new(HashMap::new()),
        }
    }
}

impl GitWatchManager {
    pub fn watch(
        &self,
        _app: AppHandle,
        project_path: String,
        on_changed: impl Fn(GitRepositoryChangeEvent) + Send + Sync + 'static,
    ) -> Result<GitWatchRegistration, String> {
        let watch_target = resolve_watch_target(&project_path)?;
        let key = watch_target.repository_key.clone();
        let registration = GitWatchRegistration {
            project_path: watch_target.project_path.clone(),
            repository_path: watch_target.repository_path.clone(),
            is_repository: watch_target.is_repository,
        };

        let mut watchers = self
            .watchers
            .lock()
            .map_err(|_| "Git watcher lock is poisoned.".to_string())?;
        if let Some(existing) = watchers.get(&key) {
            if let Ok(mut paths) = existing.project_paths.lock() {
                paths.insert(watch_target.project_path.clone());
            }
            return Ok(registration);
        }

        let project_paths_for_event = Arc::new(Mutex::new(HashSet::from([watch_target
            .project_path
            .clone()])));
        let repository_path_for_event = watch_target.repository_path.clone();
        let repository_key = watch_target.repository_key.clone();
        let git_dir_keys = watch_target.git_dir_keys.clone();
        let on_changed = Arc::new(on_changed);
        let (change_tx, change_rx) = mpsc::channel::<Vec<String>>();
        let debounced_paths = Arc::clone(&project_paths_for_event);
        let debounced_repository_path = repository_path_for_event.clone();
        let debounced_on_changed = Arc::clone(&on_changed);
        thread::Builder::new()
            .name("codux-git-watch-debounce".to_string())
            .spawn(move || {
                run_git_watch_debounce(
                    change_rx,
                    debounced_paths,
                    debounced_repository_path,
                    debounced_on_changed,
                );
            })
            .map_err(|error| error.to_string())?;
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<Event>| {
            let Ok(event) = event else {
                return;
            };
            let changed_paths = event
                .paths
                .iter()
                .filter_map(|path| {
                    let key = normalized_path_key(path);
                    should_forward_git_watch_path(&repository_key, &git_dir_keys, &key)
                        .then(|| normalized_path_display(path))
                })
                .collect::<Vec<_>>();
            if changed_paths.is_empty() {
                return;
            }
            let _ = change_tx.send(changed_paths);
        })
        .map_err(|error| error.to_string())?;

        for path in &watch_target.watch_paths {
            watcher
                .watch(path, RecursiveMode::Recursive)
                .map_err(|error| error.to_string())?;
        }

        watchers.insert(
            key,
            GitRepositoryWatcher {
                _watcher: watcher,
                project_paths: project_paths_for_event,
                _repository_path: watch_target.repository_path,
                _watch_paths: watch_target.watch_paths,
            },
        );
        Ok(registration)
    }

    pub fn unwatch(&self, project_path: String) -> Result<(), String> {
        let requested_key = normalized_path_key(Path::new(project_path.trim()));
        let repository_key = resolve_watch_target(&project_path)
            .map(|target| target.repository_key)
            .unwrap_or_else(|_| requested_key.clone());
        let mut watchers = self
            .watchers
            .lock()
            .map_err(|_| "Git watcher lock is poisoned.".to_string())?;
        if let Some(watcher) = watchers.get(&repository_key) {
            let mut should_remove = false;
            if let Ok(mut paths) = watcher.project_paths.lock() {
                should_remove = remove_watched_project_path(&mut paths, &requested_key);
            }
            if should_remove {
                watchers.remove(&repository_key);
            }
            return Ok(());
        }
        watchers.retain(|_, watcher| {
            let mut should_remove = false;
            if let Ok(mut paths) = watcher.project_paths.lock() {
                should_remove = remove_watched_project_path(&mut paths, &requested_key);
            }
            !should_remove
        });
        Ok(())
    }
}

fn run_git_watch_debounce(
    rx: mpsc::Receiver<Vec<String>>,
    watched_project_paths: Arc<Mutex<HashSet<String>>>,
    repository_path: String,
    on_changed: Arc<impl Fn(GitRepositoryChangeEvent) + Send + Sync + 'static>,
) {
    while let Ok(paths) = rx.recv() {
        let mut changed_paths = paths;
        loop {
            match rx.recv_timeout(Duration::from_millis(GIT_WATCH_DEBOUNCE_MS)) {
                Ok(next_paths) => push_unique_strings(&mut changed_paths, next_paths),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
        let project_paths = watched_project_paths
            .lock()
            .map(|paths| paths.iter().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        for project_path in project_paths {
            on_changed(GitRepositoryChangeEvent {
                project_path,
                repository_path: repository_path.clone(),
                changed_paths: changed_paths.clone(),
            });
        }
    }
}

fn push_unique_strings(target: &mut Vec<String>, values: Vec<String>) {
    for value in values {
        if !target.iter().any(|existing| existing == &value) {
            target.push(value);
        }
    }
}

fn remove_watched_project_path(paths: &mut HashSet<String>, requested_key: &str) -> bool {
    paths.retain(|path| normalized_path_key(Path::new(path)) != requested_key);
    paths.is_empty()
}

struct GitWatchTarget {
    project_path: String,
    repository_path: String,
    repository_key: String,
    git_dir_keys: Vec<String>,
    watch_paths: Vec<PathBuf>,
    is_repository: bool,
}

fn resolve_watch_target(project_path: &str) -> Result<GitWatchTarget, String> {
    let project = PathBuf::from(project_path.trim());
    if project.as_os_str().is_empty() {
        return Err("Project path cannot be empty.".to_string());
    }
    if !project.exists() {
        return Err(format!(
            "Project path does not exist: {}",
            project.display()
        ));
    }

    let project_path = normalized_path_display(&project);
    let root = repository_root(project_path.as_str()).ok();
    let is_repository = root.is_some();
    let repository_path = root.unwrap_or_else(|| project_path.clone());
    let repository_path_buf = PathBuf::from(&repository_path);
    let repository_key = normalized_path_key(&repository_path_buf);
    let git_dirs = if is_repository {
        repository_git_dirs(&repository_path_buf)
    } else {
        vec![repository_path_buf.join(".git")]
    };
    let git_dir_keys = git_dirs
        .iter()
        .map(|path| normalized_path_key(path))
        .collect::<Vec<_>>();

    let mut watch_paths = Vec::new();
    push_unique_path(&mut watch_paths, repository_path_buf);
    for git_dir in git_dirs {
        if git_dir.exists() {
            push_unique_path(&mut watch_paths, git_dir);
        }
    }

    Ok(GitWatchTarget {
        project_path,
        repository_path,
        repository_key,
        git_dir_keys,
        watch_paths,
        is_repository,
    })
}

fn repository_git_dirs(root: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(repo) = GitRepository::discover(root) {
        push_unique_path(&mut dirs, repo.path().to_path_buf());
        push_unique_path(&mut dirs, repo.commondir().to_path_buf());
    }
    if dirs.is_empty() {
        dirs.push(root.join(".git"));
    }
    dirs
}

fn push_unique_path(paths: &mut Vec<PathBuf>, path: PathBuf) {
    let key = normalized_path_key(&path);
    if paths
        .iter()
        .any(|existing| normalized_path_key(existing) == key)
    {
        return;
    }
    paths.push(path);
}

fn normalized_path_key(path: &Path) -> String {
    let normalized_path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let mut key = normalized_path.to_string_lossy().replace('\\', "/");
    while key.len() > 1 && key.ends_with('/') {
        key.pop();
    }
    #[cfg(windows)]
    {
        key = key.to_ascii_lowercase();
    }
    key
}

fn normalized_path_display(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .to_string()
}

fn should_forward_git_watch_path(
    repository_key: &str,
    git_dir_keys: &[String],
    path_key: &str,
) -> bool {
    for git_dir_key in git_dir_keys {
        let is_git_path = path_key == git_dir_key
            || path_key
                .strip_prefix(git_dir_key)
                .is_some_and(|suffix| suffix.starts_with('/'));
        if !is_git_path {
            continue;
        }

        let relative = path_key
            .strip_prefix(git_dir_key)
            .unwrap_or("")
            .trim_start_matches('/');
        return is_allowed_git_metadata_path(relative);
    }

    let repository_git_key = format!("{repository_key}/.git");
    if path_key == repository_git_key
        || path_key
            .strip_prefix(&repository_git_key)
            .is_some_and(|suffix| suffix.starts_with('/'))
    {
        let relative = path_key
            .strip_prefix(&repository_git_key)
            .unwrap_or("")
            .trim_start_matches('/');
        return is_allowed_git_metadata_path(relative);
    }

    true
}

fn is_allowed_git_metadata_path(relative: &str) -> bool {
    let relative = relative.trim_start_matches('/');
    if relative.is_empty() {
        return false;
    }

    #[cfg(windows)]
    {
        let relative = relative.to_ascii_lowercase();
        match relative.as_str() {
            "head" | "index" | "fetch_head" | "orig_head" | "packed-refs" => true,
            _ => relative.starts_with("refs/") || relative.starts_with("logs/head"),
        }
    }

    #[cfg(not(windows))]
    {
        match relative {
            "HEAD" | "index" | "FETCH_HEAD" | "ORIG_HEAD" | "packed-refs" => true,
            _ => relative.starts_with("refs/") || relative.starts_with("logs/HEAD"),
        }
    }
}

pub fn git_brief_status(project_path: String) -> GitBriefStatus {
    let repo = match open_git_repository(&project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitBriefStatus {
                branch: "uninitialized".to_string(),
                ahead: 0,
                behind: 0,
                changes: 0,
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let status = git_status_from_repo(&repo);
    GitBriefStatus {
        branch: status.branch,
        ahead: status.ahead,
        behind: status.behind,
        changes: status.staged.len() + status.unstaged.len() + status.untracked.len(),
        is_repository: true,
        error: None,
    }
}

pub fn git_status(project_path: String) -> GitStatusSnapshot {
    let repo = match open_git_repository(&project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitStatusSnapshot {
                branch: "uninitialized".to_string(),
                upstream: None,
                ahead: 0,
                behind: 0,
                staged: Vec::new(),
                unstaged: Vec::new(),
                untracked: Vec::new(),
                commits: Vec::new(),
                branches: Vec::new(),
                remote_branches: Vec::new(),
                remotes: Vec::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    git_status_from_repo(&repo)
}

pub fn git_stage(request: GitPathsRequest) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&request.project_path)?;
    if request.paths.is_empty() {
        git_output(Path::new(&root), &["add", "-A"])?;
    } else {
        let mut args = vec!["add", "--"];
        let paths = request.paths.iter().map(String::as_str).collect::<Vec<_>>();
        args.extend(paths);
        git_output(Path::new(&root), &args)?;
    }
    Ok(git_status(root))
}

pub fn git_unstage(request: GitPathsRequest) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&request.project_path)?;
    if has_resolvable_head(&root) {
        if request.paths.is_empty() {
            git_output(Path::new(&root), &["reset", "HEAD", "--", "."])?;
        } else {
            let mut args = vec!["reset", "HEAD", "--"];
            let paths = request.paths.iter().map(String::as_str).collect::<Vec<_>>();
            args.extend(paths);
            git_output(Path::new(&root), &args)?;
        }
    } else if request.paths.is_empty() {
        git_output(Path::new(&root), &["rm", "--cached", "-r", "."])?;
    } else {
        let mut args = vec!["rm", "--cached", "-r", "--"];
        let paths = request.paths.iter().map(String::as_str).collect::<Vec<_>>();
        args.extend(paths);
        git_output(Path::new(&root), &args)?;
    }
    Ok(git_status(root))
}

pub fn git_commit(request: GitCommitRequest) -> Result<GitStatusSnapshot, String> {
    let message = request.message.trim();
    if message.is_empty() {
        return Err("Commit message cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["commit", "-m", message])?;
    Ok(git_status(root))
}

pub fn git_commit_action(request: GitCommitActionRequest) -> Result<GitStatusSnapshot, String> {
    let message = request.message.trim();
    if message.is_empty() {
        return Err("Commit message cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["commit", "-m", message])?;
    match request.action.as_str() {
        "commit" => {}
        "commitAndPush" => {
            git_output(Path::new(&root), &["push"])?;
        }
        "commitAndSync" => {
            git_output(Path::new(&root), &["pull", "--rebase"])?;
            git_output(Path::new(&root), &["push"])?;
        }
        _ => return Err(format!("Unknown commit action: {}", request.action)),
    }
    Ok(git_status(root))
}

pub fn git_amend_last_commit_message(
    request: GitCommitRequest,
) -> Result<GitStatusSnapshot, String> {
    let message = request.message.trim();
    if message.is_empty() {
        return Err("Commit message cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["commit", "--amend", "-m", message])?;
    Ok(git_status(root))
}

pub fn git_last_commit_message(project_path: String) -> Result<String, String> {
    let repo = open_git_repository(&project_path)?;
    let commit = repo
        .head()
        .map_err(|error| error.message().to_string())?
        .peel_to_commit()
        .map_err(|error| error.message().to_string())?;
    Ok(commit.summary().ok().flatten().unwrap_or("").to_string())
}

pub fn git_undo_last_commit(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["reset", "--soft", "HEAD~1"])?;
    Ok(git_status(root))
}

pub fn git_head_commit_pushed(project_path: String) -> Result<bool, String> {
    let repo = open_git_repository(&project_path)?;
    let Some(head) = repo.head().ok().and_then(|head| head.target()) else {
        return Ok(false);
    };
    let Some(upstream) = upstream_branch_name(&repo) else {
        return Ok(false);
    };
    let upstream_ref = format!("refs/remotes/{upstream}");
    let Some(upstream_target) = repo
        .find_reference(&upstream_ref)
        .ok()
        .and_then(|reference| reference.target())
    else {
        return Ok(false);
    };
    Ok(repo
        .graph_descendant_of(upstream_target, head)
        .unwrap_or(false))
}

pub fn git_init(project_path: String) -> Result<GitStatusSnapshot, String> {
    let path = Path::new(project_path.trim());
    if !path.exists() {
        return Err(format!("Project path does not exist: {}", path.display()));
    }
    git_output(path, &["init"])?;
    Ok(git_status(path.display().to_string()))
}

pub fn git_clone(request: GitCloneRequest) -> Result<GitStatusSnapshot, String> {
    let remote_url = request.remote_url.trim();
    if remote_url.is_empty() {
        return Err("Remote URL cannot be empty.".to_string());
    }
    let project_path = Path::new(request.project_path.trim());
    let parent = project_path
        .parent()
        .ok_or_else(|| "Project path has no parent directory.".to_string())?;
    let folder_name = project_path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "Project folder name is invalid.".to_string())?;
    git_output(parent, &["clone", "--progress", remote_url, folder_name])?;
    Ok(git_status(project_path.display().to_string()))
}

pub fn git_discard(request: GitPathsRequest) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&request.project_path)?;
    if request.paths.is_empty() {
        let _ = git_output_permissive(
            Path::new(&root),
            &["restore", "--staged", "--worktree", "--", "."],
        );
        let _ = git_output_permissive(Path::new(&root), &["clean", "-fd"]);
    } else {
        let mut restore_args = vec!["restore", "--staged", "--worktree", "--"];
        let paths = request.paths.iter().map(String::as_str).collect::<Vec<_>>();
        restore_args.extend(paths.iter().copied());
        let _ = git_output_permissive(Path::new(&root), &restore_args);

        let mut clean_args = vec!["clean", "-fd", "--"];
        clean_args.extend(paths);
        let _ = git_output_permissive(Path::new(&root), &clean_args);
    }
    Ok(git_status(root))
}

pub fn git_branches(project_path: String) -> GitBranchesSnapshot {
    let repo = match open_git_repository(&project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitBranchesSnapshot {
                current: String::new(),
                local: Vec::new(),
                remote: Vec::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let current = current_branch_name(&repo);
    let local = git2_branches(&repo, git2::BranchType::Local, &current);
    let remote = git2_branches(&repo, git2::BranchType::Remote, &current)
        .into_iter()
        .filter(|branch| !branch.name.ends_with("/HEAD"))
        .collect();
    GitBranchesSnapshot {
        current,
        local,
        remote,
        is_repository: true,
        error: None,
    }
}

pub fn git_checkout_branch(request: GitBranchRequest) -> Result<GitStatusSnapshot, String> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["checkout", branch])?;
    Ok(git_status(root))
}

pub fn git_create_branch(request: GitCreateBranchRequest) -> Result<GitStatusSnapshot, String> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    let from = request
        .from
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    if request.checkout {
        if let Some(from) = from {
            git_output(Path::new(&root), &["checkout", "-b", branch, from])?;
        } else {
            git_output(Path::new(&root), &["checkout", "-b", branch])?;
        }
    } else if let Some(from) = from {
        git_output(Path::new(&root), &["branch", branch, from])?;
    } else {
        git_output(Path::new(&root), &["branch", branch])?;
    }
    Ok(git_status(root))
}

pub fn git_checkout_remote_branch(request: GitBranchRequest) -> Result<GitStatusSnapshot, String> {
    let remote_branch = request.branch.trim();
    if remote_branch.is_empty() {
        return Err("Remote branch name cannot be empty.".to_string());
    }
    let local_name = remote_branch
        .split_once('/')
        .map(|(_, branch)| branch)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(remote_branch);
    let root = repository_root(&request.project_path)?;
    git_output(
        Path::new(&root),
        &["checkout", "-b", local_name, "--track", remote_branch],
    )?;
    Ok(git_status(root))
}

pub fn git_merge_branch(request: GitBranchRequest) -> Result<GitStatusSnapshot, String> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["merge", branch])?;
    Ok(git_status(root))
}

pub fn git_squash_merge_branch(request: GitBranchRequest) -> Result<GitStatusSnapshot, String> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["merge", "--squash", branch])?;
    Ok(git_status(root))
}

pub fn git_delete_branch(request: GitDeleteBranchRequest) -> Result<GitStatusSnapshot, String> {
    let branch = request.branch.trim();
    if branch.is_empty() {
        return Err("Branch name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(
        Path::new(&root),
        &["branch", if request.force { "-D" } else { "-d" }, branch],
    )?;
    Ok(git_status(root))
}

pub fn git_checkout_commit(request: GitCommitRefRequest) -> Result<GitStatusSnapshot, String> {
    let commit = request.commit.trim();
    if commit.is_empty() {
        return Err("Commit cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["checkout", commit])?;
    Ok(git_status(root))
}

pub fn git_revert_commit(request: GitCommitRefRequest) -> Result<GitStatusSnapshot, String> {
    let commit = request.commit.trim();
    if commit.is_empty() {
        return Err("Commit cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["revert", "--no-edit", commit])?;
    Ok(git_status(root))
}

pub fn git_restore_commit(request: GitRestoreCommitRequest) -> Result<GitStatusSnapshot, String> {
    let commit = request.commit.trim();
    if commit.is_empty() {
        return Err("Commit cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["reset", "--hard", commit])?;
    if request.force_remote {
        git_output(Path::new(&root), &["push", "--force-with-lease"])?;
    }
    Ok(git_status(root))
}

pub fn git_add_remote(request: GitRemoteRequest) -> Result<GitStatusSnapshot, String> {
    let name = request.name.trim();
    let url = request.url.as_deref().map(str::trim).unwrap_or("");
    if name.is_empty() {
        return Err("Remote name cannot be empty.".to_string());
    }
    if url.is_empty() {
        return Err("Remote URL cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["remote", "add", name, url])?;
    Ok(git_status(root))
}

pub fn git_remove_remote(request: GitRemoteRequest) -> Result<GitStatusSnapshot, String> {
    let name = request.name.trim();
    if name.is_empty() {
        return Err("Remote name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    git_output(Path::new(&root), &["remote", "remove", name])?;
    Ok(git_status(root))
}

pub fn git_append_gitignore(request: GitPathsRequest) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&request.project_path)?;
    let additions = request
        .paths
        .iter()
        .map(|path| path.trim())
        .filter(|path| !path.is_empty())
        .collect::<Vec<_>>();
    if additions.is_empty() {
        return Ok(git_status(root));
    }
    let gitignore_path = Path::new(&root).join(".gitignore");
    let existing = std::fs::read_to_string(&gitignore_path).unwrap_or_default();
    let existing_lines = existing
        .lines()
        .map(str::trim)
        .collect::<std::collections::HashSet<_>>();
    let next = additions
        .into_iter()
        .filter(|path| !existing_lines.contains(path))
        .collect::<Vec<_>>();
    if next.is_empty() {
        return Ok(git_status(root));
    }
    let mut content = existing;
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }
    content.push_str(&next.join("\n"));
    content.push('\n');
    std::fs::write(gitignore_path, content).map_err(|error| error.to_string())?;
    Ok(git_status(root))
}

pub fn git_fetch(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["fetch"])?;
    Ok(git_status(root))
}

pub fn git_sync(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["pull", "--rebase"])?;
    git_output(Path::new(&root), &["push"])?;
    Ok(git_status(root))
}

pub fn git_push_remote(request: GitPushRemoteRequest) -> Result<GitStatusSnapshot, String> {
    let remote = request.remote.trim();
    if remote.is_empty() {
        return Err("Remote name cannot be empty.".to_string());
    }
    let root = repository_root(&request.project_path)?;
    let branch = current_local_branch_name(&root)?;
    if branch.is_empty() {
        return Err("Cannot push detached HEAD to a remote.".to_string());
    }
    git_output(Path::new(&root), &["push", "-u", remote, branch.as_str()])?;
    Ok(git_status(root))
}

pub fn git_push_remote_branch(
    request: GitPushRemoteBranchRequest,
) -> Result<GitStatusSnapshot, String> {
    let remote_branch = request.remote_branch.trim();
    if remote_branch.is_empty() {
        return Err("Remote branch cannot be empty.".to_string());
    }
    let (remote, branch_name) = remote_branch
        .split_once('/')
        .ok_or_else(|| "Remote branch must include a remote name.".to_string())?;
    let root = repository_root(&request.project_path)?;
    let local_branch = match request
        .local_branch
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(branch) => branch.to_string(),
        None => current_local_branch_name(&root)?,
    };
    if local_branch.is_empty() {
        return Err("Cannot push detached HEAD to a remote branch.".to_string());
    }
    let refspec = format!("{local_branch}:{branch_name}");
    git_output(Path::new(&root), &["push", remote, refspec.as_str()])?;
    Ok(git_status(root))
}

pub fn git_pull(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["pull", "--rebase"])?;
    Ok(git_status(root))
}

pub fn git_push(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["push"])?;
    Ok(git_status(root))
}

pub fn git_force_push(project_path: String) -> Result<GitStatusSnapshot, String> {
    let root = repository_root(&project_path)?;
    git_output(Path::new(&root), &["push", "--force-with-lease"])?;
    Ok(git_status(root))
}

pub fn git_diff_file(request: GitDiffRequest) -> GitDiffSnapshot {
    let repo = match open_git_repository(&request.project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitDiffSnapshot {
                path: request.path,
                diff: String::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let path = request.path.trim();
    if path.is_empty() {
        return GitDiffSnapshot {
            path: String::new(),
            diff: String::new(),
            is_repository: true,
            error: Some("File path cannot be empty.".to_string()),
        };
    }
    let diff = if request.staged {
        git2_diff_to_string(&repo, DiffTarget::Index, Some(path), 3)
    } else {
        git2_diff_to_string(&repo, DiffTarget::Worktree, Some(path), 3)
    }
    .unwrap_or_default();
    let diff = if diff.trim().is_empty() {
        if !request.staged && is_untracked_path_git2(&repo, path) {
            format!("Untracked file: {path}\n\nStage the file to include it in the next commit.")
        } else {
            diff
        }
    } else {
        diff
    };
    GitDiffSnapshot {
        path: path.to_string(),
        diff,
        is_repository: true,
        error: None,
    }
}

pub fn git_review_diff_file(request: GitReviewDiffRequest) -> GitDiffSnapshot {
    let repo = match open_git_repository(&request.project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitDiffSnapshot {
                path: request.path,
                diff: String::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let path = request.path.trim();
    if path.is_empty() {
        return GitDiffSnapshot {
            path: String::new(),
            diff: String::new(),
            is_repository: true,
            error: Some("File path cannot be empty.".to_string()),
        };
    }
    let base = request
        .base_branch
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty() && *value != "current branch");

    let diff = if let Some(base) = base {
        git2_commit_diff_to_string(&repo, base, Some(path), 3).unwrap_or_default()
    } else {
        let unstaged =
            git2_diff_to_string(&repo, DiffTarget::Worktree, Some(path), 3).unwrap_or_default();
        let staged =
            git2_diff_to_string(&repo, DiffTarget::Index, Some(path), 3).unwrap_or_default();
        match (staged.trim().is_empty(), unstaged.trim().is_empty()) {
            (true, true) if is_untracked_path_git2(&repo, path) => {
                format!(
                    "Untracked file: {path}\n\nStage the file to include it in the next commit."
                )
            }
            (true, _) => unstaged,
            (_, true) => staged,
            _ => format!("{staged}\n{unstaged}"),
        }
    };

    GitDiffSnapshot {
        path: path.to_string(),
        diff,
        is_repository: true,
        error: None,
    }
}

pub fn git_review_file_content(request: GitReviewContentRequest) -> GitReviewContentSnapshot {
    let repo = match open_git_repository(&request.project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitReviewContentSnapshot {
                path: request.path,
                head_content: String::new(),
                base_content: None,
                index_content: None,
                worktree_content: String::new(),
                added_lines: Vec::new(),
                deleted_lines: Vec::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let path = request.path.trim();
    if path.is_empty() {
        return GitReviewContentSnapshot {
            path: String::new(),
            head_content: String::new(),
            base_content: None,
            index_content: None,
            worktree_content: String::new(),
            added_lines: Vec::new(),
            deleted_lines: Vec::new(),
            is_repository: true,
            error: Some("File path cannot be empty.".to_string()),
        };
    }

    let base = request
        .base_branch
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty() && *value != "current branch");
    let head_content = git2_blob_or_empty(&repo, "HEAD", path);
    let base_content = base.map(|reference| git2_blob_or_empty(&repo, reference, path));
    let index_content = git2_index_blob(&repo, path).ok();
    let worktree_content = read_worktree_file(repo_root(&repo), path).unwrap_or_default();
    let diff = if let Some(base) = base {
        git2_commit_diff_to_string(&repo, base, Some(path), 0).unwrap_or_default()
    } else {
        let unstaged =
            git2_diff_to_string(&repo, DiffTarget::Worktree, Some(path), 0).unwrap_or_default();
        let staged =
            git2_diff_to_string(&repo, DiffTarget::Index, Some(path), 0).unwrap_or_default();
        match (staged.trim().is_empty(), unstaged.trim().is_empty()) {
            (true, _) => unstaged,
            (_, true) => staged,
            _ => format!("{staged}\n{unstaged}"),
        }
    };
    let (deleted_lines, added_lines) = parse_diff_line_numbers(&diff);

    GitReviewContentSnapshot {
        path: path.to_string(),
        head_content,
        base_content,
        index_content,
        worktree_content,
        added_lines,
        deleted_lines,
        is_repository: true,
        error: None,
    }
}

pub fn git_review(project_path: String, base_branch: Option<String>) -> GitReviewSnapshot {
    let repo = match open_git_repository(&project_path) {
        Ok(repo) => repo,
        Err(error) => {
            return GitReviewSnapshot {
                mode: "workingTreeAudit".to_string(),
                title: "Uncommitted Audit".to_string(),
                base_branch,
                diff_stat: String::new(),
                files: Vec::new(),
                is_repository: false,
                error: Some(error),
            };
        }
    };
    let root = repo_root(&repo);
    let base = base_branch
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty() && *value != "current branch")
        .map(str::to_string);

    if let Some(base) = base {
        let files = git2_commit_review_files(&repo, &base).unwrap_or_default();
        let diff_stat = review_diff_stat(&files);
        return GitReviewSnapshot {
            mode: "taskBranch".to_string(),
            title: "Worktree Review".to_string(),
            base_branch: Some(base),
            diff_stat,
            files,
            is_repository: true,
            error: None,
        };
    }

    let status = git_status_from_repo(&repo);
    let stats = working_tree_review_stats_git2(&repo);
    let mut seen_paths = HashSet::new();
    let mut files = Vec::new();
    for file in &status.staged {
        push_review_file_from_status(&mut files, &mut seen_paths, file, "staged", &stats, root);
    }
    for file in &status.unstaged {
        push_review_file_from_status(&mut files, &mut seen_paths, file, "modified", &stats, root);
    }
    for file in &status.untracked {
        push_review_file_from_status(&mut files, &mut seen_paths, file, "added", &stats, root);
    }
    GitReviewSnapshot {
        mode: "workingTreeAudit".to_string(),
        title: "Uncommitted Audit".to_string(),
        base_branch: None,
        diff_stat: if files.is_empty() {
            String::new()
        } else {
            format!("{} changed files", files.len())
        },
        files,
        is_repository: true,
        error: None,
    }
}

fn open_git_repository(path: &str) -> Result<GitRepository, String> {
    let path = Path::new(path.trim());
    if path.as_os_str().is_empty() {
        return Err("Project path cannot be empty.".to_string());
    }
    GitRepository::discover(path).map_err(|error| error.message().to_string())
}

fn repo_root(repo: &GitRepository) -> &Path {
    repo.workdir()
        .or_else(|| repo.path().parent())
        .unwrap_or_else(|| Path::new(""))
}

fn git_status_from_repo(repo: &GitRepository) -> GitStatusSnapshot {
    let branch = current_branch_name(repo);
    let upstream = upstream_branch_name(repo);
    let (ahead, behind) = ahead_behind(repo).unwrap_or((0, 0));
    let (staged, unstaged, untracked) = git2_status_files(repo);
    let commits = git2_commit_log(repo, 20);
    let branches = git2_branches(repo, git2::BranchType::Local, &branch);
    let remote_branches = git2_branches(repo, git2::BranchType::Remote, &branch)
        .into_iter()
        .map(|branch| branch.name)
        .filter(|name| !name.ends_with("/HEAD") && name.contains('/'))
        .collect();
    let remotes = git2_remotes(repo);
    GitStatusSnapshot {
        branch,
        upstream,
        ahead,
        behind,
        staged,
        unstaged,
        untracked,
        commits,
        branches,
        remote_branches,
        remotes,
        is_repository: true,
        error: None,
    }
}

fn current_branch_name(repo: &GitRepository) -> String {
    repo.head()
        .ok()
        .and_then(|head| {
            if head.is_branch() {
                head.shorthand().ok().map(str::to_string)
            } else {
                head.target().map(|oid| short_oid(oid))
            }
        })
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "HEAD".to_string())
}

fn upstream_branch_name(repo: &GitRepository) -> Option<String> {
    let head = repo.head().ok()?;
    if !head.is_branch() {
        return None;
    }
    let name = head.shorthand().ok()?;
    repo.find_branch(name, git2::BranchType::Local)
        .ok()
        .and_then(|branch| branch.upstream().ok())
        .and_then(|branch| branch.name().ok().flatten().map(str::to_string))
}

fn ahead_behind(repo: &GitRepository) -> Option<(i64, i64)> {
    let head = repo.head().ok()?.target()?;
    let upstream = {
        let head_ref = repo.head().ok()?;
        if !head_ref.is_branch() {
            return Some((0, 0));
        }
        let name = head_ref.shorthand().ok()?;
        repo.find_branch(name, git2::BranchType::Local)
            .ok()?
            .upstream()
            .ok()?
            .get()
            .target()?
    };
    repo.graph_ahead_behind(head, upstream)
        .ok()
        .map(|(ahead, behind)| (ahead as i64, behind as i64))
}

fn git2_status_files(
    repo: &GitRepository,
) -> (Vec<GitFileStatus>, Vec<GitFileStatus>, Vec<GitFileStatus>) {
    let mut options = git2::StatusOptions::new();
    options
        .include_untracked(true)
        .recurse_untracked_dirs(true)
        .renames_head_to_index(true)
        .renames_index_to_workdir(true);
    let statuses = match repo.statuses(Some(&mut options)) {
        Ok(statuses) => statuses,
        Err(_) => return (Vec::new(), Vec::new(), Vec::new()),
    };
    let mut staged = Vec::new();
    let mut unstaged = Vec::new();
    let mut untracked = Vec::new();
    for entry in statuses.iter() {
        let status = entry.status();
        let Some(path) = entry.path().ok().map(normalize_git_path) else {
            continue;
        };
        let index_status = git2_index_status_code(status);
        let worktree_status = git2_worktree_status_code(status);
        let file = GitFileStatus {
            path,
            index_status: index_status.clone(),
            worktree_status: worktree_status.clone(),
        };
        if status.contains(git2::Status::WT_NEW) && index_status.trim().is_empty() {
            untracked.push(file);
            continue;
        }
        if !index_status.trim().is_empty() {
            staged.push(file.clone());
        }
        if !worktree_status.trim().is_empty() {
            unstaged.push(file);
        }
    }
    (staged, unstaged, untracked)
}

fn git2_index_status_code(status: git2::Status) -> String {
    if status.contains(git2::Status::INDEX_NEW) {
        "A"
    } else if status.contains(git2::Status::INDEX_MODIFIED) {
        "M"
    } else if status.contains(git2::Status::INDEX_DELETED) {
        "D"
    } else if status.contains(git2::Status::INDEX_RENAMED) {
        "R"
    } else if status.contains(git2::Status::INDEX_TYPECHANGE) {
        "T"
    } else {
        " "
    }
    .to_string()
}

fn git2_worktree_status_code(status: git2::Status) -> String {
    if status.contains(git2::Status::WT_NEW) {
        "?"
    } else if status.contains(git2::Status::WT_MODIFIED) {
        "M"
    } else if status.contains(git2::Status::WT_DELETED) {
        "D"
    } else if status.contains(git2::Status::WT_RENAMED) {
        "R"
    } else if status.contains(git2::Status::WT_TYPECHANGE) {
        "T"
    } else {
        " "
    }
    .to_string()
}

fn git2_commit_log(repo: &GitRepository, limit: usize) -> Vec<GitCommitSummary> {
    let mut revwalk = match repo.revwalk() {
        Ok(revwalk) => revwalk,
        Err(_) => return Vec::new(),
    };
    let _ = revwalk.set_sorting(git2::Sort::TIME);
    if revwalk.push_head().is_err() {
        return Vec::new();
    }
    revwalk
        .take(limit)
        .filter_map(Result::ok)
        .filter_map(|oid| {
            let commit = repo.find_commit(oid).ok()?;
            let author = commit.author().name().unwrap_or("").to_string();
            Some(GitCommitSummary {
                hash: oid.to_string(),
                title: commit.summary().ok().flatten().unwrap_or("").to_string(),
                relative_time: relative_git_time(commit.time().seconds()),
                decorations: commit_decorations(repo, oid),
                graph_prefix: String::new(),
                author,
            })
        })
        .collect()
}

fn commit_decorations(repo: &GitRepository, oid: git2::Oid) -> Option<String> {
    let mut labels = Vec::new();
    if let Ok(head) = repo.head() {
        if head.target() == Some(oid) {
            if let Ok(name) = head.shorthand() {
                labels.push(format!("HEAD -> {name}"));
            } else {
                labels.push("HEAD".to_string());
            }
        }
    }
    if let Ok(mut refs) = repo.references() {
        while let Some(Ok(reference)) = refs.next() {
            if reference.target() != Some(oid) {
                continue;
            }
            let Ok(name) = reference.shorthand() else {
                continue;
            };
            if reference.is_tag() {
                labels.push(format!("tag: {name}"));
            } else if reference.is_branch() && !labels.iter().any(|item| item.contains(name)) {
                labels.push(name.to_string());
            } else if reference.is_remote() {
                labels.push(name.to_string());
            }
        }
    }
    (!labels.is_empty()).then(|| labels.join(", "))
}

fn git2_branches(
    repo: &GitRepository,
    branch_type: git2::BranchType,
    current: &str,
) -> Vec<GitBranchSummary> {
    let mut branches = Vec::new();
    let Ok(iter) = repo.branches(Some(branch_type)) else {
        return branches;
    };
    for item in iter.filter_map(Result::ok) {
        let branch = item.0;
        let name = branch
            .name()
            .ok()
            .flatten()
            .map(str::to_string)
            .unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        let upstream = branch
            .upstream()
            .ok()
            .and_then(|branch| branch.name().ok().flatten().map(str::to_string));
        let hash = branch.get().target().map(short_oid).unwrap_or_default();
        branches.push(GitBranchSummary {
            is_current: branch_type == git2::BranchType::Local && name == current,
            name,
            upstream,
            hash,
        });
    }
    branches.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
    if branch_type == git2::BranchType::Local {
        ensure_current_local_branch(branches, current)
    } else {
        branches
    }
}

fn git2_remotes(repo: &GitRepository) -> Vec<GitRemoteSummary> {
    let mut remotes = Vec::new();
    let Ok(names) = repo.remotes() else {
        return remotes;
    };
    for name in names.iter().flatten().flatten() {
        if let Ok(remote) = repo.find_remote(name) {
            remotes.push(GitRemoteSummary {
                name: name.to_string(),
                url: remote.url().unwrap_or("").to_string(),
            });
        }
    }
    remotes.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
    remotes
}

#[derive(Clone, Copy)]
enum DiffTarget {
    Index,
    Worktree,
}

fn git2_diff_to_string(
    repo: &GitRepository,
    target: DiffTarget,
    path: Option<&str>,
    context_lines: u32,
) -> Result<String, String> {
    let tree = head_tree(repo).ok();
    let mut options = git2_diff_options(path, context_lines);
    let diff = match target {
        DiffTarget::Index => repo.diff_tree_to_index(tree.as_ref(), None, Some(&mut options)),
        DiffTarget::Worktree => repo.diff_index_to_workdir(None, Some(&mut options)),
    }
    .map_err(|error| error.message().to_string())?;
    diff_to_string(&diff)
}

fn git2_commit_diff_to_string(
    repo: &GitRepository,
    base: &str,
    path: Option<&str>,
    context_lines: u32,
) -> Result<String, String> {
    let base_tree = resolve_commit_tree(repo, base)?;
    let head_tree = head_tree(repo)?;
    let mut options = git2_diff_options(path, context_lines);
    let diff = repo
        .diff_tree_to_tree(Some(&base_tree), Some(&head_tree), Some(&mut options))
        .map_err(|error| error.message().to_string())?;
    diff_to_string(&diff)
}

fn git2_commit_review_files(
    repo: &GitRepository,
    base: &str,
) -> Result<Vec<GitReviewFile>, String> {
    let base_tree = resolve_commit_tree(repo, base)?;
    let head_tree = head_tree(repo)?;
    let mut diff = repo
        .diff_tree_to_tree(Some(&base_tree), Some(&head_tree), None)
        .map_err(|error| error.message().to_string())?;
    let _ = diff.find_similar(None);
    review_files_from_diff(&diff)
}

fn working_tree_review_stats_git2(repo: &GitRepository) -> HashMap<String, (i64, i64)> {
    let mut stats = HashMap::new();
    if let Ok(diff) = diff_for_review_stats(repo, DiffTarget::Index) {
        merge_review_stats_from_diff(&mut stats, &diff);
    }
    if let Ok(diff) = diff_for_review_stats(repo, DiffTarget::Worktree) {
        merge_review_stats_from_diff(&mut stats, &diff);
    }
    stats
}

fn diff_for_review_stats(
    repo: &GitRepository,
    target: DiffTarget,
) -> Result<git2::Diff<'_>, String> {
    let tree = head_tree(repo).ok();
    let diff = match target {
        DiffTarget::Index => repo.diff_tree_to_index(tree.as_ref(), None, None),
        DiffTarget::Worktree => repo.diff_index_to_workdir(None, None),
    }
    .map_err(|error| error.message().to_string())?;
    Ok(diff)
}

fn merge_review_stats_from_diff(target: &mut HashMap<String, (i64, i64)>, diff: &git2::Diff<'_>) {
    for file in review_files_from_diff(diff).unwrap_or_default() {
        let entry = target.entry(file.path).or_insert((0, 0));
        entry.0 += file.additions;
        entry.1 += file.deletions;
    }
}

fn review_files_from_diff(diff: &git2::Diff<'_>) -> Result<Vec<GitReviewFile>, String> {
    let mut files = Vec::new();
    for index in 0..diff.deltas().len() {
        let Some(delta) = diff.get_delta(index) else {
            continue;
        };
        let Some(path) = delta
            .new_file()
            .path()
            .or_else(|| delta.old_file().path())
            .map(normalize_git_path_path)
        else {
            continue;
        };
        let (additions, deletions) = patch_line_stats(diff, index);
        files.push(GitReviewFile {
            path,
            status: review_status_from_delta(delta.status()),
            additions,
            deletions,
        });
    }
    Ok(files)
}

fn patch_line_stats(diff: &git2::Diff<'_>, index: usize) -> (i64, i64) {
    let Some(delta) = diff.get_delta(index) else {
        return (0, 0);
    };
    let Ok(Some(patch)) = git2::Patch::from_diff(diff, index) else {
        return (0, 0);
    };
    let mut additions = 0;
    let mut deletions = 0;
    for hunk_index in 0..patch.num_hunks() {
        let Ok((_hunk, line_count)) = patch.hunk(hunk_index) else {
            continue;
        };
        for line_index in 0..line_count {
            let Ok(line) = patch.line_in_hunk(hunk_index, line_index) else {
                continue;
            };
            match line.origin() {
                '+' => additions += 1,
                '-' => deletions += 1,
                _ => {}
            }
        }
    }
    if additions == 0 && deletions == 0 {
        match delta.status() {
            git2::Delta::Added => additions = 1,
            git2::Delta::Deleted => deletions = 1,
            _ => {}
        }
    }
    (additions, deletions)
}

fn diff_to_string(diff: &git2::Diff<'_>) -> Result<String, String> {
    let mut output = Vec::new();
    diff.print(git2::DiffFormat::Patch, |_delta, _hunk, line| {
        output.extend_from_slice(line.content());
        true
    })
    .map_err(|error| error.message().to_string())?;
    Ok(String::from_utf8_lossy(&output).to_string())
}

fn git2_diff_options(path: Option<&str>, context_lines: u32) -> git2::DiffOptions {
    let mut options = git2::DiffOptions::new();
    options
        .include_untracked(true)
        .recurse_untracked_dirs(true)
        .context_lines(context_lines);
    if let Some(path) = path.filter(|path| !path.trim().is_empty()) {
        options.pathspec(path);
    }
    options
}

fn head_tree(repo: &GitRepository) -> Result<git2::Tree<'_>, String> {
    let head = repo.head().map_err(|error| error.message().to_string())?;
    let commit = head
        .peel_to_commit()
        .map_err(|error| error.message().to_string())?;
    commit.tree().map_err(|error| error.message().to_string())
}

fn resolve_commit_tree<'repo>(
    repo: &'repo GitRepository,
    reference: &str,
) -> Result<git2::Tree<'repo>, String> {
    let object = repo
        .revparse_single(reference)
        .map_err(|_| format!("Cannot resolve git reference: {reference}"))?;
    let commit = object
        .peel_to_commit()
        .map_err(|error| error.message().to_string())?;
    commit.tree().map_err(|error| error.message().to_string())
}

fn git2_blob_or_empty(repo: &GitRepository, reference: &str, path: &str) -> String {
    git2_blob(repo, reference, path).unwrap_or_default()
}

fn git2_blob(repo: &GitRepository, reference: &str, path: &str) -> Result<String, String> {
    let tree = resolve_commit_tree(repo, reference)?;
    let entry = tree
        .get_path(Path::new(path))
        .map_err(|error| error.message().to_string())?;
    let blob = repo
        .find_blob(entry.id())
        .map_err(|error| error.message().to_string())?;
    Ok(String::from_utf8_lossy(blob.content()).to_string())
}

fn git2_index_blob(repo: &GitRepository, path: &str) -> Result<String, String> {
    let index = repo.index().map_err(|error| error.message().to_string())?;
    let entry = index
        .get_path(Path::new(path), 0)
        .ok_or_else(|| "Index entry not found.".to_string())?;
    let blob = repo
        .find_blob(entry.id)
        .map_err(|error| error.message().to_string())?;
    Ok(String::from_utf8_lossy(blob.content()).to_string())
}

fn is_untracked_path_git2(repo: &GitRepository, path: &str) -> bool {
    let (.., untracked) = git2_status_files(repo);
    untracked.iter().any(|file| file.path == path)
}

fn review_status_from_delta(delta: git2::Delta) -> String {
    match delta {
        git2::Delta::Added => "added",
        git2::Delta::Deleted => "deleted",
        git2::Delta::Renamed => "renamed",
        git2::Delta::Copied => "copied",
        git2::Delta::Typechange => "typeChanged",
        _ => "modified",
    }
    .to_string()
}

fn review_diff_stat(files: &[GitReviewFile]) -> String {
    if files.is_empty() {
        return String::new();
    }
    let additions: i64 = files.iter().map(|file| file.additions).sum();
    let deletions: i64 = files.iter().map(|file| file.deletions).sum();
    format!(
        "{} changed files, {} insertions(+), {} deletions(-)",
        files.len(),
        additions,
        deletions
    )
}

fn short_oid(oid: git2::Oid) -> String {
    oid.to_string().chars().take(7).collect()
}

fn relative_git_time(seconds: i64) -> String {
    let now = chrono::Utc::now().timestamp();
    let elapsed = now.saturating_sub(seconds).max(0);
    if elapsed < 60 {
        "just now".to_string()
    } else if elapsed < 3_600 {
        format!("{} minutes ago", elapsed / 60)
    } else if elapsed < 86_400 {
        format!("{} hours ago", elapsed / 3_600)
    } else if elapsed < 2_592_000 {
        format!("{} days ago", elapsed / 86_400)
    } else if elapsed < 31_536_000 {
        format!("{} months ago", elapsed / 2_592_000)
    } else {
        format!("{} years ago", elapsed / 31_536_000)
    }
}

fn normalize_git_path(value: &str) -> String {
    value.replace('\\', "/")
}

fn normalize_git_path_path(path: &Path) -> String {
    normalize_git_path(&path.to_string_lossy())
}

fn read_worktree_file(root: &Path, path: &str) -> Result<String, String> {
    let full_path = root.join(path);
    let root = root.canonicalize().map_err(|error| error.to_string())?;
    let full_path = full_path
        .canonicalize()
        .map_err(|error| error.to_string())?;
    if !full_path.starts_with(&root) || !full_path.is_file() {
        return Ok(String::new());
    }
    std::fs::read_to_string(full_path).map_err(|error| error.to_string())
}

fn parse_diff_line_numbers(diff: &str) -> (Vec<i64>, Vec<i64>) {
    let mut deleted = Vec::new();
    let mut added = Vec::new();
    for line in diff.lines() {
        let Some(header) = line.strip_prefix("@@ ") else {
            continue;
        };
        let Some(end) = header.find(" @@") else {
            continue;
        };
        let hunk = &header[..end];
        let mut parts = hunk.split_whitespace();
        if let Some(old_range) = parts.next() {
            deleted.extend(diff_range_lines(old_range.trim_start_matches('-')));
        }
        if let Some(new_range) = parts.next() {
            added.extend(diff_range_lines(new_range.trim_start_matches('+')));
        }
    }
    (deleted, added)
}

fn diff_range_lines(range: &str) -> Vec<i64> {
    let mut parts = range.split(',');
    let start = parts
        .next()
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(0);
    let count = parts
        .next()
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(1);
    if start <= 0 || count <= 0 {
        return Vec::new();
    }
    (start..start + count).collect()
}

fn ensure_current_local_branch(
    mut branches: Vec<GitBranchSummary>,
    current: &str,
) -> Vec<GitBranchSummary> {
    let current = current.trim();
    if current.is_empty() || current == "HEAD" || current == "uninitialized" {
        return branches;
    }
    for branch in &mut branches {
        branch.is_current = branch.name == current;
    }
    branches
}

fn push_review_file_from_status(
    files: &mut Vec<GitReviewFile>,
    seen_paths: &mut HashSet<String>,
    file: &GitFileStatus,
    fallback: &str,
    stats: &HashMap<String, (i64, i64)>,
    root: &Path,
) {
    if !seen_paths.insert(file.path.clone()) {
        return;
    }
    let mut review_file = review_file_from_status(file, fallback, stats);
    if file.index_status == "?" && file.worktree_status == "?" && review_file.additions == 0 {
        review_file.additions = count_untracked_file_lines(root, &file.path).unwrap_or(0);
    }
    files.push(review_file);
}

fn count_untracked_file_lines(root: &Path, path: &str) -> Option<i64> {
    let root = root.canonicalize().ok()?;
    let full_path = root.join(path).canonicalize().ok()?;
    if !full_path.starts_with(&root) || !full_path.is_file() {
        return None;
    }
    let metadata = std::fs::metadata(&full_path).ok()?;
    if metadata.len() > REVIEW_UNTRACKED_LINE_COUNT_LIMIT_BYTES {
        return None;
    }
    let data = std::fs::read(full_path).ok()?;
    if data.contains(&0) {
        return None;
    }
    let text = String::from_utf8_lossy(&data);
    Some(text.lines().count() as i64)
}

fn review_file_from_status(
    file: &GitFileStatus,
    fallback: &str,
    stats: &HashMap<String, (i64, i64)>,
) -> GitReviewFile {
    let status = if file.index_status == "?" && file.worktree_status == "?" {
        "added".to_string()
    } else {
        review_status(
            file.worktree_status
                .trim()
                .chars()
                .next()
                .or_else(|| file.index_status.trim().chars().next())
                .map(|value| value.to_string())
                .as_deref()
                .unwrap_or(fallback),
        )
    };
    let (additions, deletions) = stats.get(&file.path).copied().unwrap_or((0, 0));
    GitReviewFile {
        path: file.path.clone(),
        status,
        additions,
        deletions,
    }
}

fn review_status(value: &str) -> String {
    match value.chars().next().unwrap_or('M') {
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        'C' => "copied",
        'T' => "typeChanged",
        '?' => "added",
        _ => "modified",
    }
    .to_string()
}

fn git_output(cwd: &Path, args: &[&str]) -> Result<String, String> {
    git_command_output(cwd, args)
}

fn git_output_permissive(cwd: &Path, args: &[&str]) -> Result<String, String> {
    git_command_output_permissive(cwd, args)
}

pub(crate) fn git_command_output(cwd: &Path, args: &[&str]) -> Result<String, String> {
    let output = run_git_command(cwd, args)?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            format!("git {:?} failed", args)
        } else {
            stderr
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub(crate) fn git_command_output_permissive(cwd: &Path, args: &[&str]) -> Result<String, String> {
    let output = run_git_command(cwd, args)?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    if output.status.success() || !stdout.trim().is_empty() {
        return Ok(stdout);
    }
    Ok(String::new())
}

fn run_git_command(cwd: &Path, args: &[&str]) -> Result<Output, String> {
    const GIT_COMMAND_TIMEOUT: Duration = Duration::from_secs(8);
    let _guard = GIT_COMMAND_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| "Git command queue is unavailable.".to_string())?;
    let mut child = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    let deadline = Instant::now() + GIT_COMMAND_TIMEOUT;
    loop {
        if child
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_some()
        {
            return child.wait_with_output().map_err(|error| error.to_string());
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("git {:?} timed out", args));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn repository_root(path: &str) -> Result<String, String> {
    open_git_repository(path).map(|repo| repo_root(&repo).display().to_string())
}

fn current_local_branch_name(path: &str) -> Result<String, String> {
    let repo = open_git_repository(path)?;
    let head = repo.head().map_err(|error| error.message().to_string())?;
    if !head.is_branch() {
        return Ok(String::new());
    }
    head.shorthand()
        .map(str::to_string)
        .map_err(|error| error.message().to_string())
}

fn has_resolvable_head(path: &str) -> bool {
    open_git_repository(path)
        .map(|repo| repo.head().ok().and_then(|head| head.target()).is_some())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn git_watch_filter_allows_worktree_and_known_metadata() {
        let repository = "/repo/app";
        let git_dirs = vec!["/repo/app/.git".to_string()];

        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/src/main.rs"
        ));
        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/HEAD"
        ));
        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/index"
        ));
        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/refs/heads/main"
        ));
        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/logs/HEAD"
        ));
        assert!(should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/FETCH_HEAD"
        ));
    }

    #[test]
    fn git_watch_filter_ignores_git_object_churn() {
        let repository = "/repo/app";
        let git_dirs = vec!["/repo/app/.git".to_string()];

        assert!(!should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git"
        ));
        assert!(!should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/objects/ab/cdef"
        ));
        assert!(!should_forward_git_watch_path(
            repository,
            &git_dirs,
            "/repo/app/.git/modules/dependency/config"
        ));
    }

    #[test]
    fn git_watcher_path_set_keeps_other_worktrees_when_one_is_removed() {
        let mut paths = HashSet::from([
            "/repo/app".to_string(),
            "/repo/app/.codux/worktrees/task-a".to_string(),
        ]);

        let empty = remove_watched_project_path(
            &mut paths,
            &normalized_path_key(Path::new("/repo/app/.codux/worktrees/task-a")),
        );

        assert!(!empty);
        assert_eq!(paths, HashSet::from(["/repo/app".to_string()]));
    }

    #[test]
    fn git_watcher_path_set_reports_empty_after_last_path_is_removed() {
        let mut paths = HashSet::from(["/repo/app".to_string()]);

        let empty =
            remove_watched_project_path(&mut paths, &normalized_path_key(Path::new("/repo/app")));

        assert!(empty);
        assert!(paths.is_empty());
    }
}
