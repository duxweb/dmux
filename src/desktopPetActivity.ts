export type AISessionSnapshot = {
  state: "idle" | "responding" | "needsInput";
  tool: string;
  updatedAt: number;
  hasCompletedTurn: boolean;
  wasInterrupted: boolean;
  notificationType?: string | null;
  targetToolName?: string | null;
  message?: string | null;
  latestAssistantPreview?: string | null;
};

const DESKTOP_PET_COMPLETED_STATUS_SECONDS = 8;

export function desktopPetActivityLine(sessions: AISessionSnapshot[], now: number) {
  const visibleSessions = sessions.filter((session) => {
    if (session.state === "responding" || session.state === "needsInput") return true;
    return session.hasCompletedTurn && now - session.updatedAt <= DESKTOP_PET_COMPLETED_STATUS_SECONDS;
  });
  if (!visibleSessions.length) return "";
  const permission = visibleSessions
    .filter(
      (session) => session.state === "needsInput" && isPermissionRequestNotificationType(session.notificationType),
    )
    .sort(compareUpdatedDesc)[0];
  if (permission) {
    return permission.targetToolName
      ? `${permission.tool} needs permission for ${permission.targetToolName}`
      : `${permission.tool} needs permission`;
  }
  const needsInput = visibleSessions.filter((session) => session.state === "needsInput").sort(compareUpdatedDesc)[0];
  if (needsInput) {
    return normalizedPreview(needsInput.message) || `${needsInput.tool} needs input`;
  }
  const running = visibleSessions.filter((session) => session.state === "responding").sort(compareUpdatedDesc)[0];
  if (running) {
    return normalizedPreview(running.latestAssistantPreview) || `${running.tool} is running`;
  }
  const completed = visibleSessions.filter((session) => session.hasCompletedTurn).sort(compareUpdatedDesc)[0];
  if (completed) return completed.wasInterrupted ? `${completed.tool} failed` : `${completed.tool} completed`;
  return "";
}

export function nextDesktopPetActivityRefreshMs(sessions: AISessionSnapshot[], now: number) {
  const nextExpiry = sessions
    .filter((session) => session.hasCompletedTurn && session.state !== "responding" && session.state !== "needsInput")
    .map((session) => session.updatedAt + DESKTOP_PET_COMPLETED_STATUS_SECONDS)
    .filter((expiresAt) => expiresAt > now)
    .sort((left, right) => left - right)[0];
  return nextExpiry ? Math.max(250, Math.ceil((nextExpiry - now) * 1000)) : null;
}

function compareUpdatedDesc(left: AISessionSnapshot, right: AISessionSnapshot) {
  return right.updatedAt - left.updatedAt;
}

function isPermissionRequestNotificationType(value?: string | null) {
  return value === "PermissionRequest" || value === "permission-request" || value === "permission_request";
}

function normalizedPreview(value?: string | null) {
  const preview = (value ?? "")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 3)
    .join("\n")
    .trim();
  if (!preview) return "";
  return preview.length > 120 ? `${preview.slice(0, 119)}...` : preview;
}
