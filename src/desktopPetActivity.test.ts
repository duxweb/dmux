import { describe, expect, it } from "vitest";
import { desktopPetActivityLine, nextDesktopPetActivityRefreshMs, type AISessionSnapshot } from "./desktopPetActivity";

function session(patch: Partial<AISessionSnapshot>): AISessionSnapshot {
  return {
    state: "idle",
    tool: "codex",
    updatedAt: 100,
    hasCompletedTurn: false,
    wasInterrupted: false,
    ...patch,
  };
}

describe("desktop pet activity", () => {
  it("shows live assistant previews while an AI runtime is responding", () => {
    expect(
      desktopPetActivityLine(
        [
          session({
            state: "responding",
            latestAssistantPreview: "我先检查项目结构。\n然后确认入口和配置。",
          }),
        ],
        101,
      ),
    ).toBe("我先检查项目结构。\n然后确认入口和配置。");
  });

  it("keeps the bubble hidden when no runtime activity is visible", () => {
    expect(desktopPetActivityLine([session({ updatedAt: 10 })], 100)).toBe("");
    expect(nextDesktopPetActivityRefreshMs([session({ updatedAt: 10 })], 100)).toBeNull();
  });
});
