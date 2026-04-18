#!/bin/zsh
set -uo pipefail

zmodload zsh/datetime 2>/dev/null || true

action="${1:-}"
tool_name="${2:-${DMUX_ACTIVE_AI_TOOL:-}}"
hook_payload="$(cat)"
notification_type=""
should_send_response_event=1

if [[ -z "${DMUX_SESSION_ID:-}" || -z "${DMUX_PROJECT_ID:-}" || -z "${tool_name:-}" ]]; then
  exit 0
fi

case "${action}" in
  session-start)
    response_state="idle"
    ;;
  prompt-submit|pre-tool-use|post-tool-use|before-agent|permission-request)
    response_state="responding"
    ;;
  notification)
    notification_type="$(HOOK_PAYLOAD="${hook_payload}" /usr/bin/python3 - <<'PY'
import json
import os

payload = os.environ.get("HOOK_PAYLOAD", "")
if not payload:
    raise SystemExit(0)

try:
    obj = json.loads(payload)
except Exception:
    raise SystemExit(0)

def first_string(mapping, *keys):
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, str) and value:
            return value
    return None

value = first_string(obj, "notification_type")
if value is None:
    value = first_string(obj.get("notification"), "notification_type", "type", "kind", "reason")
if value is None:
    value = first_string(obj.get("data"), "notification_type", "type", "kind", "reason")
if value:
    print(value)
PY
)"
    if [[ "${notification_type:-}" == "idle_prompt" ]]; then
      response_state="idle"
    else
      response_state=""
      should_send_response_event=0
    fi
    ;;
  stop|stop-failure|session-end|idle|after-agent)
    response_state="idle"
    ;;
  codex-prompt-submit|codex-stop)
    response_state=""
    ;;
  *)
    exit 0
    ;;
esac

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  print -rn -- "$value"
}

now() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf "%.3f" "${EPOCHREALTIME}"
  elif [[ -n "${EPOCHSECONDS:-}" ]]; then
    printf "%.3f" "${EPOCHSECONDS}"
  else
    /bin/date +%s | awk '{ printf "%.3f", $1 }'
  fi
}

log_line() {
  [[ -n "${DMUX_LOG_FILE:-}" ]] || return 0
  /bin/mkdir -p -- "${DMUX_LOG_FILE:h}"
  print -r -- "[$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')] [wrapper] $1" >> "${DMUX_LOG_FILE}"
}

extract_hook_session_id() {
  [[ -n "${hook_payload}" ]] || return 0
  HOOK_PAYLOAD="${hook_payload}" /usr/bin/python3 - <<'PY'
import json
import os
import sys

payload = os.environ.get("HOOK_PAYLOAD", "")
if not payload:
    raise SystemExit(0)

try:
    obj = json.loads(payload)
except Exception:
    raise SystemExit(0)

stack = [obj]
seen = set()
while stack:
    current = stack.pop()
    ident = id(current)
    if ident in seen:
        continue
    seen.add(ident)

    if isinstance(current, dict):
        for key in ("session_id", "sessionId"):
            value = current.get(key)
            if isinstance(value, str) and value:
                print(value)
                raise SystemExit(0)
        stack.extend(current.values())
    elif isinstance(current, list):
        stack.extend(current)
PY
}

resolved_claude_external_session_id() {
  local parsed_session_id
  parsed_session_id="$(extract_hook_session_id)"
  if [[ -n "${parsed_session_id}" ]]; then
    print -r -- "${parsed_session_id}"
    return 0
  fi

  if [[ -n "${DMUX_EXTERNAL_SESSION_ID:-}" ]]; then
    print -r -- "${DMUX_EXTERNAL_SESSION_ID}"
  fi
}

write_claude_session_map() {
  local external_session_id
  external_session_id="$(resolved_claude_external_session_id)"
  [[ -n "${DMUX_CLAUDE_SESSION_MAP_DIR:-}" && -n "${DMUX_SESSION_ID:-}" && -n "${external_session_id:-}" ]] || return 0
  local path="${DMUX_CLAUDE_SESSION_MAP_DIR}/${DMUX_SESSION_ID}.json"
  local tmp="${path}.tmp"
  /bin/mkdir -p -- "${DMUX_CLAUDE_SESSION_MAP_DIR}"
  {
    print -rn -- '{'
    print -rn -- "\"sessionId\":\"$(json_escape "${DMUX_SESSION_ID}")\","
    print -rn -- "\"externalSessionID\":\"$(json_escape "${external_session_id}")\","
    print -rn -- "\"updatedAt\":$(now)"
    print -r -- '}'
  } >| "${tmp}"
  /bin/mv -f -- "${tmp}" "${path}"
  log_line "claude map write session=${DMUX_SESSION_ID} externalSession=${external_session_id}"
}

clear_response_file() {
  return 0
}

send_runtime_event() {
  local payload="$1"
  [[ -n "${DMUX_RUNTIME_SOCKET:-}" ]] || {
    log_line "hook skip action=${action} tool=${tool_name} reason=no-runtime-socket"
    return 0
  }
  command -v /usr/bin/nc >/dev/null 2>&1 || {
    log_line "hook skip action=${action} tool=${tool_name} reason=no-nc"
    return 0
  }
  if print -r -- "${payload}" | /usr/bin/nc -U -w 1 "${DMUX_RUNTIME_SOCKET}" >/dev/null 2>&1; then
    log_line "hook sent action=${action} tool=${tool_name} socket=${DMUX_RUNTIME_SOCKET}"
  else
    log_line "hook send failed action=${action} tool=${tool_name} socket=${DMUX_RUNTIME_SOCKET}"
  fi
}

clear_claude_session_map() {
  [[ -n "${DMUX_CLAUDE_SESSION_MAP_DIR:-}" ]] || return 0
  /bin/rm -f -- "${DMUX_CLAUDE_SESSION_MAP_DIR}/${DMUX_SESSION_ID}.json"
}

write_codex_hook_event() {
  local event_name="$1"
  local event_json
  event_json="$(
    {
      print -rn -- '{"kind":"codex-hook","payload":{'
      print -rn -- "\"event\":\"$(json_escape "${event_name}")\","
      print -rn -- "\"tool\":\"$(json_escape "${tool_name}")\","
      print -rn -- "\"dmuxSessionId\":\"$(json_escape "${DMUX_SESSION_ID}")\","
      print -rn -- "\"dmuxProjectId\":\"$(json_escape "${DMUX_PROJECT_ID}")\","
      print -rn -- "\"dmuxProjectPath\":\"$(json_escape "${DMUX_PROJECT_PATH:-}")\","
      print -rn -- "\"receivedAt\":$(now),"
      print -rn -- "\"payload\":\"$(json_escape "${hook_payload}")\""
      print -rn -- '}}'
    }
  )"
  send_runtime_event "${event_json}"
  log_line "codex hook event=${event_name} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID}"
}

write_claude_hook_event() {
  local event_name="$1"
  local event_json
  event_json="$(
    {
      print -rn -- '{"kind":"claude-hook","payload":{'
      print -rn -- "\"event\":\"$(json_escape "${event_name}")\","
      print -rn -- "\"tool\":\"$(json_escape "${tool_name}")\","
      print -rn -- "\"dmuxSessionId\":\"$(json_escape "${DMUX_SESSION_ID}")\","
      print -rn -- "\"dmuxProjectId\":\"$(json_escape "${DMUX_PROJECT_ID}")\","
      print -rn -- "\"dmuxProjectPath\":\"$(json_escape "${DMUX_PROJECT_PATH:-}")\","
      print -rn -- "\"receivedAt\":$(now),"
      print -rn -- "\"payload\":\"$(json_escape "${hook_payload}")\""
      print -rn -- '}}'
    }
  )"
  send_runtime_event "${event_json}"
  log_line "claude hook event=${event_name} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID}"
}

write_gemini_hook_event() {
  local event_name="$1"
  local event_json
  event_json="$(
    {
      print -rn -- '{"kind":"gemini-hook","payload":{'
      print -rn -- "\"event\":\"$(json_escape "${event_name}")\","
      print -rn -- "\"tool\":\"$(json_escape "${tool_name}")\","
      print -rn -- "\"dmuxSessionId\":\"$(json_escape "${DMUX_SESSION_ID}")\","
      print -rn -- "\"dmuxProjectId\":\"$(json_escape "${DMUX_PROJECT_ID}")\","
      print -rn -- "\"dmuxProjectPath\":\"$(json_escape "${DMUX_PROJECT_PATH:-}")\","
      print -rn -- "\"receivedAt\":$(now),"
      print -rn -- "\"payload\":\"$(json_escape "${hook_payload}")\""
      print -rn -- '}}'
    }
  )"
  send_runtime_event "${event_json}"
  log_line "gemini hook event=${event_name} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID}"
}

case "${action}" in
  codex-prompt-submit)
    write_codex_hook_event "UserPromptSubmit"
    exit 0
    ;;
  codex-stop)
    write_codex_hook_event "Stop"
    exit 0
    ;;
esac

if [[ "${tool_name}" == "claude" || "${tool_name}" == "claude-code" ]]; then
  case "${action}" in
    session-start)
      write_claude_session_map
      log_line "claude hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-} externalSession=$(resolved_claude_external_session_id || print -r -- nil)"
      write_claude_hook_event "SessionStart"
      ;;
    prompt-submit|pre-tool-use|post-tool-use|permission-request|notification)
      write_claude_session_map
      if [[ "${action}" == "notification" ]]; then
        log_line "claude hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-} notificationType=${notification_type:-unknown}"
      else
        log_line "claude hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-}"
      fi
      case "${action}" in
        prompt-submit) write_claude_hook_event "UserPromptSubmit" ;;
        pre-tool-use) write_claude_hook_event "PreToolUse" ;;
        post-tool-use) write_claude_hook_event "PostToolUse" ;;
        permission-request) write_claude_hook_event "PermissionRequest" ;;
        notification) write_claude_hook_event "Notification" ;;
      esac
      ;;
    stop|stop-failure|idle)
      write_claude_session_map
      log_line "claude hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-}"
      case "${action}" in
        stop) write_claude_hook_event "Stop" ;;
        stop-failure) write_claude_hook_event "StopFailure" ;;
        idle) write_claude_hook_event "Idle" ;;
      esac
      ;;
    session-end)
      log_line "claude hook action=${action} clear-response session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-}"
      clear_response_file
      write_claude_hook_event "SessionEnd"
      clear_claude_session_map
      ;;
  esac
fi

if [[ "${tool_name}" == "gemini" ]]; then
  case "${action}" in
    session-start|before-agent|after-agent)
      log_line "gemini hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-}"
      case "${action}" in
        session-start) write_gemini_hook_event "SessionStart" ;;
        before-agent) write_gemini_hook_event "BeforeAgent" ;;
        after-agent) write_gemini_hook_event "AfterAgent" ;;
      esac
      ;;
    session-end)
      log_line "gemini hook action=${action} session=${DMUX_SESSION_ID} project=${DMUX_PROJECT_ID:-}"
      write_gemini_hook_event "SessionEnd"
      ;;
  esac
fi

if [[ "${should_send_response_event}" != "1" || -z "${DMUX_RUNTIME_SOCKET:-}" ]]; then
  exit 0
fi

response_json="$(
  {
    print -rn -- '{"kind":"response","payload":{'
    print -rn -- "\"sessionId\":\"$(json_escape "${DMUX_SESSION_ID}")\","
    print -rn -- "\"sessionInstanceId\":\"$(json_escape "${DMUX_SESSION_INSTANCE_ID:-}")\","
    if [[ -n "${DMUX_ACTIVE_AI_INVOCATION_ID:-}" ]]; then
      print -rn -- "\"invocationId\":\"$(json_escape "${DMUX_ACTIVE_AI_INVOCATION_ID}")\","
    else
      print -rn -- "\"invocationId\":null,"
    fi
    print -rn -- "\"projectId\":\"$(json_escape "${DMUX_PROJECT_ID}")\","
    print -rn -- "\"projectPath\":\"$(json_escape "${DMUX_PROJECT_PATH:-}")\","
    print -rn -- "\"tool\":\"$(json_escape "${tool_name}")\","
    print -rn -- "\"responseState\":\"$(json_escape "${response_state}")\","
    print -rn -- "\"updatedAt\":$(now)"
    print -rn -- '}}'
  }
)"
send_runtime_event "${response_json}"
