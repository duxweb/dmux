if [[ -n "${DMUX_AI_HOOK_INSTALLED:-}" ]]; then
  return 0
fi
export DMUX_AI_HOOK_INSTALLED=1

zmodload zsh/datetime 2>/dev/null || true
autoload -Uz add-zsh-hook

typeset -g DMUX_ACTIVE_AI_TOOL=""
typeset -g DMUX_ACTIVE_AI_STARTED_AT=""
typeset -g DMUX_ACTIVE_AI_INVOCATION_ID=""
typeset -g DMUX_ACTIVE_AI_RESOLVED_PATH=""
export DMUX_ACTIVE_AI_TOOL
export DMUX_ACTIVE_AI_STARTED_AT
export DMUX_ACTIVE_AI_INVOCATION_ID
export DMUX_ACTIVE_AI_RESOLVED_PATH

_dmux_log_line() {
  [[ -n "${DMUX_LOG_FILE:-}" ]] || return 0
  /bin/mkdir -p -- "${DMUX_LOG_FILE:h}"
  print -r -- "[$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')] [zsh-hook] $1" >> "${DMUX_LOG_FILE}"
}

_dmux_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  print -rn -- "$value"
}

_dmux_now() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf "%.3f" "${EPOCHREALTIME}"
  else
    printf "%.3f" "${EPOCHSECONDS:-0}"
  fi
}

_dmux_new_invocation_id() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

_dmux_reset_terminal_input_modes() {
  [[ -t 1 ]] || return 0
  printf '\033[<u' || true
}

_dmux_prepend_wrapper_bin() {
  [[ -n "${DMUX_WRAPPER_BIN:-}" && -d "${DMUX_WRAPPER_BIN}" ]] || return 0
  typeset -gaU path
  path=("${DMUX_WRAPPER_BIN}" ${path:#"${DMUX_WRAPPER_BIN}"})
  export PATH
}

_dmux_resolve_tool_from_command() {
  local command_line="$1"
  local -a words
  words=(${(z)command_line})
  local index=1

  while (( index <= ${#words} )); do
    local candidate="${words[index]}"
    if [[ "${candidate}" == [A-Za-z_][A-Za-z0-9_]*=* ]]; then
      (( index++ ))
      continue
    fi
    case "${candidate}" in
      env|command|builtin|noglob|nocorrect|time|nohup)
        (( index++ ))
        continue
        ;;
    esac
    candidate="${candidate:t}"
    case "${candidate}" in
      codex|claude|claude-code|opencode|gemini)
        print -r -- "${candidate}"
        return 0
        ;;
    esac
    break
  done
  return 1
}

_dmux_ai_preexec() {
  local tool
  tool="$(_dmux_resolve_tool_from_command "$1")" || return 0
  DMUX_ACTIVE_AI_TOOL="${tool}"
  DMUX_ACTIVE_AI_STARTED_AT="$(_dmux_now)"
  DMUX_ACTIVE_AI_INVOCATION_ID="$(_dmux_new_invocation_id)"
  local resolved_path=""
  resolved_path="$(PATH="${DMUX_ORIGINAL_PATH:-$PATH}" whence -p "${tool}" 2>/dev/null || true)"
  DMUX_ACTIVE_AI_RESOLVED_PATH="${resolved_path}"
  export DMUX_ACTIVE_AI_TOOL
  export DMUX_ACTIVE_AI_STARTED_AT
  export DMUX_ACTIVE_AI_INVOCATION_ID
  export DMUX_ACTIVE_AI_RESOLVED_PATH
  _dmux_prepend_wrapper_bin
  _dmux_log_line "preexec tool=${tool} resolved=${resolved_path:-nil} wrapper=${DMUX_WRAPPER_BIN:-nil} session=${DMUX_SESSION_ID:-nil} invocation=${DMUX_ACTIVE_AI_INVOCATION_ID:-nil}"
}

_dmux_ai_precmd() {
  [[ -n "${DMUX_ACTIVE_AI_TOOL}" ]] || return 0
  _dmux_reset_terminal_input_modes
  DMUX_ACTIVE_AI_TOOL=""
  DMUX_ACTIVE_AI_STARTED_AT=""
  DMUX_ACTIVE_AI_INVOCATION_ID=""
  DMUX_ACTIVE_AI_RESOLVED_PATH=""
  export DMUX_ACTIVE_AI_TOOL
  export DMUX_ACTIVE_AI_STARTED_AT
  export DMUX_ACTIVE_AI_INVOCATION_ID
  export DMUX_ACTIVE_AI_RESOLVED_PATH
}

_dmux_ai_zshexit() {
  if [[ -n "${DMUX_ACTIVE_AI_TOOL}" ]]; then
    _dmux_reset_terminal_input_modes
  fi
  DMUX_ACTIVE_AI_TOOL=""
  DMUX_ACTIVE_AI_STARTED_AT=""
  DMUX_ACTIVE_AI_INVOCATION_ID=""
  DMUX_ACTIVE_AI_RESOLVED_PATH=""
  export DMUX_ACTIVE_AI_TOOL
  export DMUX_ACTIVE_AI_STARTED_AT
  export DMUX_ACTIVE_AI_INVOCATION_ID
  export DMUX_ACTIVE_AI_RESOLVED_PATH
}

add-zsh-hook preexec _dmux_ai_preexec
add-zsh-hook precmd _dmux_ai_precmd
add-zsh-hook zshexit _dmux_ai_zshexit

_dmux_prepend_wrapper_bin
_dmux_reset_terminal_input_modes
_dmux_log_line "loaded session=${DMUX_SESSION_ID:-nil} wrapper=${DMUX_WRAPPER_BIN:-nil} claude=$(whence -p claude 2>/dev/null || print -r -- nil) codex=$(whence -p codex 2>/dev/null || print -r -- nil)"
