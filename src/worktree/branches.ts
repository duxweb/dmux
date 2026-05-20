import { tm } from "../i18n";
import type { GitBranchesSnapshot } from "../git/status";

export function worktreeBranchOptions(branches: string[]) {
  const seen = new Set<string>();
  const options: string[] = [];
  const add = (value?: string | null) => {
    const branch = value?.trim();
    if (!branch || seen.has(branch) || branch === tm("worktree.branch.current", "current branch")) return;
    seen.add(branch);
    options.push(branch);
  };
  for (const branch of branches) add(branch);
  return options;
}

export function gitBranchNamesFromSnapshot(snapshot: GitBranchesSnapshot) {
  if (!snapshot.isRepository) return [];
  return worktreeBranchOptions([snapshot.current, ...snapshot.local.map((branch) => branch.name)]);
}
