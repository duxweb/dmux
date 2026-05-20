import { create } from "zustand";
import type { AIGlobalHistorySnapshot, AIHistoryProjectState } from "./ai/history";
import type { AIRuntimeStateSnapshot } from "./ai/types";
import type { GitStatusSnapshot } from "./git/status";
import type { WorktreeSnapshot } from "./worktree/snapshot";

export type GitStatusCacheEntry = {
  snapshot: GitStatusSnapshot;
  error: string | null;
  updatedAt: number;
};

export type WorktreeCacheEntry = {
  snapshot: WorktreeSnapshot;
  error: string | null;
  updatedAt: number;
};

type RuntimeState = {
  gitStatusByPath: Record<string, GitStatusCacheEntry>;
  worktreeSnapshotByKey: Record<string, WorktreeCacheEntry>;
  aiProjectStateByKey: Record<string, AIHistoryProjectState>;
  aiGlobalHistory: AIGlobalHistorySnapshot | null;
  aiRuntimeSnapshot: AIRuntimeStateSnapshot | null;
  aiGlobalStatus: {
    isLoading: boolean;
    error: string | null;
  };
  gitLoadingByPath: Record<string, boolean>;
  gitErrorByPath: Record<string, string | null>;
  worktreeLoadingByKey: Record<string, boolean>;
  worktreeErrorByKey: Record<string, string | null>;
  setGitStatus: (pathKey: string, entry: GitStatusCacheEntry) => void;
  setGitLoading: (pathKey: string, isLoading: boolean) => void;
  setGitError: (pathKey: string, error: string | null) => void;
  setWorktreeSnapshot: (key: string, entry: WorktreeCacheEntry) => void;
  setWorktreeLoading: (key: string, isLoading: boolean) => void;
  setWorktreeError: (key: string, error: string | null) => void;
  setAIProjectState: (key: string, state: AIHistoryProjectState) => void;
  setAIRuntimeSnapshot: (snapshot: AIRuntimeStateSnapshot | null) => void;
  updateAIProjectStateByProjectId: (
    projectId: string,
    updater: (state: AIHistoryProjectState, key: string) => AIHistoryProjectState,
  ) => void;
  setAIGlobalHistory: (snapshot: AIGlobalHistorySnapshot | null) => void;
  setAIGlobalStatus: (status: { isLoading?: boolean; error?: string | null }) => void;
};

export const useRuntimeStore = create<RuntimeState>((set) => ({
  gitStatusByPath: {},
  worktreeSnapshotByKey: {},
  aiProjectStateByKey: {},
  aiGlobalHistory: null,
  aiRuntimeSnapshot: null,
  aiGlobalStatus: {
    isLoading: false,
    error: null,
  },
  gitLoadingByPath: {},
  gitErrorByPath: {},
  worktreeLoadingByKey: {},
  worktreeErrorByKey: {},
  setGitStatus: (pathKey, entry) =>
    set((state) => ({
      gitStatusByPath: {
        ...state.gitStatusByPath,
        [pathKey]: entry,
      },
      gitErrorByPath: {
        ...state.gitErrorByPath,
        [pathKey]: entry.error,
      },
    })),
  setGitLoading: (pathKey, isLoading) =>
    set((state) => ({
      gitLoadingByPath: {
        ...state.gitLoadingByPath,
        [pathKey]: isLoading,
      },
    })),
  setGitError: (pathKey, error) =>
    set((state) => ({
      gitErrorByPath: {
        ...state.gitErrorByPath,
        [pathKey]: error,
      },
    })),
  setWorktreeSnapshot: (key, entry) =>
    set((state) => ({
      worktreeSnapshotByKey: {
        ...state.worktreeSnapshotByKey,
        [key]: entry,
      },
      worktreeErrorByKey: {
        ...state.worktreeErrorByKey,
        [key]: entry.error,
      },
    })),
  setWorktreeLoading: (key, isLoading) =>
    set((state) => ({
      worktreeLoadingByKey: {
        ...state.worktreeLoadingByKey,
        [key]: isLoading,
      },
    })),
  setWorktreeError: (key, error) =>
    set((state) => ({
      worktreeErrorByKey: {
        ...state.worktreeErrorByKey,
        [key]: error,
      },
    })),
  setAIProjectState: (key, projectState) =>
    set((state) => ({
      aiProjectStateByKey: {
        ...state.aiProjectStateByKey,
        [key]: projectState,
      },
    })),
  setAIRuntimeSnapshot: (snapshot) => set({ aiRuntimeSnapshot: snapshot }),
  updateAIProjectStateByProjectId: (projectId, updater) =>
    set((state) => {
      const entry = Object.entries(state.aiProjectStateByKey).find(([, value]) => value.projectId === projectId);
      if (!entry) return state;
      const [key, value] = entry;
      return {
        aiProjectStateByKey: {
          ...state.aiProjectStateByKey,
          [key]: updater(value, key),
        },
      };
    }),
  setAIGlobalHistory: (snapshot) => set({ aiGlobalHistory: snapshot }),
  setAIGlobalStatus: (status) =>
    set((state) => ({
      aiGlobalStatus: {
        ...state.aiGlobalStatus,
        ...status,
      },
    })),
}));
