import { describe, expect, it } from "vitest";
import type { GitBranchesSnapshot } from "../git/status";
import { gitBranchNamesFromSnapshot } from "../worktree/branches";

describe("worktree branch options", () => {
  it("uses only the current and local git branches for worktree base branch choices", () => {
    const snapshot: GitBranchesSnapshot = {
      current: "main",
      local: [
        {
          name: "main",
          upstream: null,
          hash: "abc123",
          isCurrent: true,
        },
      ],
      remote: [
        {
          name: "origin/main",
          upstream: null,
          hash: "abc123",
          isCurrent: false,
        },
      ],
      isRepository: true,
      error: null,
    };

    expect(gitBranchNamesFromSnapshot(snapshot)).toEqual(["main"]);
  });

  it("does not synthesize fallback branches for an empty repository snapshot", () => {
    const snapshot: GitBranchesSnapshot = {
      current: "",
      local: [],
      remote: [],
      isRepository: true,
      error: null,
    };

    expect(gitBranchNamesFromSnapshot(snapshot)).toEqual([]);
  });
});
