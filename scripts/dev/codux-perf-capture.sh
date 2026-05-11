#!/usr/bin/env zsh
set -euo pipefail

duration=120
interval=1
label="codux-perf"
bundle_id=""
process_path=""
sample_seconds=5

usage() {
  cat <<'EOF'
usage: scripts/dev/codux-perf-capture.sh [options]

Options:
  --bundle-id ID      Match a running app by bundle identifier.
  --process-path PATH Match a running process by executable path.
  --duration SECONDS  Capture duration. Default: 120.
  --interval SECONDS  Poll interval. Default: 1.
  --label NAME        Output label. Default: codux-perf.

Examples:
  scripts/dev/codux-perf-capture.sh --bundle-id com.duxweb.dmux --label formal-0.9.10
  scripts/dev/codux-perf-capture.sh --bundle-id com.duxweb.codux.dev --label dev-current

CPU and child-process samples are scoped to the matched PID. Log deltas come
from the shared Codux log files, so run only one Codux instance for clean log
delta comparisons.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id)
      bundle_id="${2:-}"
      shift 2
      ;;
    --process-path)
      process_path="${2:-}"
      shift 2
      ;;
    --duration)
      duration="${2:-}"
      shift 2
      ;;
    --interval)
      interval="${2:-}"
      shift 2
      ;;
    --label)
      label="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${bundle_id}" && -z "${process_path}" ]]; then
  bundle_id="com.duxweb.dmux"
fi

if ! [[ "${duration}" == <-> ]] || (( duration <= 0 )); then
  print -u2 -- "--duration must be a positive integer"
  exit 2
fi

if ! [[ "${interval}" == <-> ]] || (( interval <= 0 )); then
  print -u2 -- "--interval must be a positive integer"
  exit 2
fi

find_pid_by_bundle_id() {
  local id="$1"
  local asn
  asn="$(/usr/bin/lsappinfo list 2>/dev/null | /usr/bin/awk -v target="${id}" '
    /^[0-9]+\)/ {
      current = ""
      if (match($0, /ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+/)) {
        current = substr($0, RSTART, RLENGTH)
      }
    }
    /bundleID="/ {
      bundle = $0
      sub(/^.*bundleID="/, "", bundle)
      sub(/".*$/, "", bundle)
      if (bundle == target && found == "") {
        found = current
      }
    }
    END { if (found != "") print found }
  ')"
  [[ -n "${asn}" ]] || return 0
  /usr/bin/lsappinfo info -only pid "${asn}" 2>/dev/null |
    /usr/bin/awk -F= '/"pid"/ { gsub(/[^0-9]/, "", $2); print $2 }'
}

find_pid_by_process_path() {
  local path="$1"
  /bin/ps -axo pid=,command= | /usr/bin/awk -v target="${path}" '
    {
      cmd = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", cmd)
      if (pid == "" && (cmd == target || index(cmd, target " ") == 1)) {
        pid = $1
      }
    }
    END { if (pid != "") print pid }
  '
}

pid=""
if [[ -n "${process_path}" ]]; then
  pid="$(find_pid_by_process_path "${process_path}")"
else
  pid="$(find_pid_by_bundle_id "${bundle_id}")"
fi

if [[ -z "${pid}" ]]; then
  print -u2 -- "no running Codux process matched"
  print -u2 -- "bundle_id=${bundle_id:-nil} process_path=${process_path:-nil}"
  exit 1
fi

timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
safe_label="$(print -r -- "${label}" | /usr/bin/tr -cs '[:alnum:]._-+' '-')"
out_dir="${TMPDIR:-/tmp}/codux-perf-${safe_label}-${timestamp}"
/bin/mkdir -p "${out_dir}"

runtime_log="${HOME}/Library/Application Support/Codux/logs/runtime.log"
live_log="${HOME}/Library/Application Support/Codux/logs/live.log"
summary_file="${out_dir}/summary.txt"
samples_file="${out_dir}/process-samples.tsv"
children_file="${out_dir}/child-process-samples.tsv"
sample_file="${out_dir}/sample.txt"

descendants_of() {
  local root="$1"
  local frontier=("${root}")
  local result=()
  while (( ${#frontier[@]} > 0 )); do
    local next=()
    for parent in "${frontier[@]}"; do
      local kids
      kids=("${(@f)$(/usr/bin/pgrep -P "${parent}" 2>/dev/null || true)}")
      for child in "${kids[@]}"; do
        [[ -z "${child}" ]] && continue
        result+=("${child}")
        next+=("${child}")
      done
    done
    frontier=("${next[@]}")
  done
  print -r -- "${result[@]}"
}

line_count() {
  local file="$1"
  [[ -f "${file}" ]] || {
    print -- 0
    return
  }
  /usr/bin/wc -l < "${file}" | /usr/bin/tr -d ' '
}

pattern_count() {
  local file="$1"
  local pattern="$2"
  [[ -f "${file}" ]] || {
    print -- 0
    return
  }
  /usr/bin/grep -F -c -- "${pattern}" "${file}" 2>/dev/null || true
}

runtime_start_lines="$(line_count "${runtime_log}")"
live_start_lines="$(line_count "${live_log}")"
remote_fallback_start="$(pattern_count "${runtime_log}" "fallback relay terminal data type=terminal.output")"
ai_runtime_start="$(pattern_count "${live_log}" "[ai-session-store] source=Codux runtime terminal=")"

{
  print -- "label=${label}"
  print -- "pid=${pid}"
  print -- "bundle_id=${bundle_id:-nil}"
  print -- "process_path=${process_path:-nil}"
  print -- "started_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  print -- "duration=${duration}"
  print -- "interval=${interval}"
  print -- "log_delta_scope=shared_codux_log_files"
  print -- "runtime_log=${runtime_log}"
  print -- "live_log=${live_log}"
} > "${summary_file}"

print -- "timestamp\tpid\tcpu\tmem\trss_kb\tetime\tcommand" > "${samples_file}"
print -- "timestamp\tpid\tppid\tcpu\tmem\trss_kb\tetime\tcommand" > "${children_file}"

end_at=$(( $(/bin/date +%s) + duration ))
while (( $(/bin/date +%s) < end_at )); do
  now="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! /bin/kill -0 "${pid}" 2>/dev/null; then
    print -u2 -- "process exited pid=${pid}"
    break
  fi

  /bin/ps -p "${pid}" -o pid=,%cpu=,%mem=,rss=,etime=,command= |
    /usr/bin/awk -v ts="${now}" '{ print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" substr($0, index($0,$6)) }' >> "${samples_file}"

  children=("${(@f)$(descendants_of "${pid}")}")
  if (( ${#children[@]} > 0 )); then
    child_csv="$(IFS=,; print -r -- "${children[*]}")"
    /bin/ps -p "${child_csv}" -o pid=,ppid=,%cpu=,%mem=,rss=,etime=,command= 2>/dev/null |
      /usr/bin/awk -v ts="${now}" '{ print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" substr($0, index($0,$7)) }' >> "${children_file}" || true
  fi

  /bin/sleep "${interval}"
done

runtime_end_lines="$(line_count "${runtime_log}")"
live_end_lines="$(line_count "${live_log}")"
remote_fallback_end="$(pattern_count "${runtime_log}" "fallback relay terminal data type=terminal.output")"
ai_runtime_end="$(pattern_count "${live_log}" "[ai-session-store] source=Codux runtime terminal=")"

if /bin/kill -0 "${pid}" 2>/dev/null; then
  /usr/bin/sample "${pid}" "${sample_seconds}" 1 -file "${sample_file}" >/dev/null 2>&1 || true
fi

avg_cpu="$(/usr/bin/awk 'NR > 1 { total += $3; count += 1 } END { if (count == 0) print "0.0"; else printf "%.1f", total / count }' "${samples_file}")"
max_cpu="$(/usr/bin/awk 'NR > 1 && $3 > max { max = $3 } END { printf "%.1f", max }' "${samples_file}")"
avg_mem="$(/usr/bin/awk 'NR > 1 { total += $4; count += 1 } END { if (count == 0) print "0.0"; else printf "%.1f", total / count }' "${samples_file}")"

{
  print -- "ended_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  print -- "avg_cpu=${avg_cpu}"
  print -- "max_cpu=${max_cpu}"
  print -- "avg_mem=${avg_mem}"
  print -- "runtime_log_lines_delta=$(( runtime_end_lines - runtime_start_lines ))"
  print -- "live_log_lines_delta=$(( live_end_lines - live_start_lines ))"
  print -- "remote_terminal_output_fallback_delta=$(( remote_fallback_end - remote_fallback_start ))"
  print -- "ai_runtime_snapshot_log_delta=$(( ai_runtime_end - ai_runtime_start ))"
  print -- "process_samples=${samples_file}"
  print -- "child_process_samples=${children_file}"
  print -- "sample=${sample_file}"
} >> "${summary_file}"

print -- "${summary_file}"
