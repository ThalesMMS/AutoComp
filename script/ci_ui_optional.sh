#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${AUTOCOMP_CI_UI_OUTPUT_DIR:-$ROOT_DIR/dist/ui-optional}"
SMOKE_SCRIPT_DIR="${AUTOCOMP_CI_UI_SCRIPT_DIR:-$ROOT_DIR/script}"
BACKEND_URL="${AUTOCOMP_REMOTE_BASE_URL:-http://100.98.1.45:8000}"
ALLOW_SKIP=0
SAFE_OVERLAY_MODE=0
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_PATH=""
RESULTS_PATH=""
LOG_DIR=""
EXIT_STATUS=0
SKIPPED_CHECKS=0
FAILED_CHECKS=0

usage() {
  cat >&2 <<'USAGE'
usage: ci_ui_optional.sh [options]

Options:
  --output-dir PATH       Directory for the optional UI report and command logs.
  --allow-skip           Return success when UI checks are skipped for missing
                         permissions or backend prerequisites.
  --safe-overlay-mode    Run inline preview smoke with AUTOCOMP_SAFE_OVERLAY_MODE=1.
  --backend-url URL      Backend URL preflighted before settings/backend smoke.

Runs permission-aware optional UI smoke coverage for prepared local Macs or
macOS runners. In strict mode, missing required permissions or backend
availability fail clearly after writing a structured report.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --allow-skip)
      ALLOW_SKIP=1
      shift
      ;;
    --safe-overlay-mode)
      SAFE_OVERLAY_MODE=1
      shift
      ;;
    --backend-url)
      BACKEND_URL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$OUTPUT_DIR" in
  ""|"/"|".")
    echo "Refusing unsafe optional UI output directory: $OUTPUT_DIR" >&2
    exit 1
    ;;
esac

mkdir -p "$OUTPUT_DIR" || exit 1
LOG_DIR="$OUTPUT_DIR/ci-ui-optional-logs-$RUN_ID"
REPORT_PATH="$OUTPUT_DIR/ci-ui-optional-$RUN_ID.md"
RESULTS_PATH="$OUTPUT_DIR/ci-ui-optional-results.tsv"
mkdir -p "$LOG_DIR" || exit 1

tsv_escape() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
}

append_result() {
  local section="$1"
  local id="$2"
  local status="$3"
  local evidence="$4"
  local note="$5"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(tsv_escape "$section")" \
    "$(tsv_escape "$id")" \
    "$(tsv_escape "$status")" \
    "$(tsv_escape "$evidence")" \
    "$(tsv_escape "$note")" >>"$RESULTS_PATH"
}

redact_log_file() {
  local log_path="$1"
  if [[ -f "$ROOT_DIR/script/qa_real_app_matrix.sh" ]]; then
    "$ROOT_DIR/script/qa_real_app_matrix.sh" --redact-log "$log_path" >/dev/null 2>&1 || true
  fi
}

status_from_override() {
  local variable="$1"
  local value="${!variable:-}"
  case "$value" in
    available|missing)
      printf '%s\n' "$value"
      return 0
      ;;
    "")
      return 1
      ;;
    *)
      printf 'unknown: invalid override %s=%s\n' "$variable" "$value"
      return 0
      ;;
  esac
}

detect_accessibility() {
  status_from_override AUTOCOMP_CI_UI_ACCESSIBILITY_STATUS && return
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'missing\n'
    return
  fi

  /usr/bin/python3 <<'PY'
import ctypes
import ctypes.util

path = ctypes.util.find_library("ApplicationServices") or "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
try:
    library = ctypes.CDLL(path)
    library.AXIsProcessTrusted.restype = ctypes.c_bool
    print("available" if library.AXIsProcessTrusted() else "missing")
except Exception as error:
    print(f"unknown: {error}")
PY
}

detect_input_monitoring() {
  status_from_override AUTOCOMP_CI_UI_INPUT_MONITORING_STATUS && return
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'missing\n'
    return
  fi

  /usr/bin/python3 <<'PY'
import ctypes
import ctypes.util

path = ctypes.util.find_library("CoreGraphics") or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
try:
    library = ctypes.CDLL(path)
    library.CGPreflightListenEventAccess.restype = ctypes.c_bool
    print("available" if library.CGPreflightListenEventAccess() else "missing")
except AttributeError:
    print("unknown: CGPreflightListenEventAccess unavailable")
except Exception as error:
    print(f"unknown: {error}")
PY
}

detect_apple_events() {
  status_from_override AUTOCOMP_CI_UI_APPLE_EVENTS_STATUS && return
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'missing\n'
    return
  fi

  if /usr/bin/osascript -e 'tell application "System Events" to get name' >/dev/null 2>&1; then
    printf 'available\n'
  else
    printf 'missing\n'
  fi
}

detect_backend() {
  status_from_override AUTOCOMP_CI_UI_BACKEND_STATUS && return
  /usr/bin/python3 - "$BACKEND_URL" <<'PY'
import socket
import sys
from urllib.parse import urlparse

raw_url = sys.argv[1]
parsed = urlparse(raw_url)
if not parsed.scheme or not parsed.hostname:
    print("missing")
    sys.exit(0)

port = parsed.port
if port is None:
    port = 443 if parsed.scheme == "https" else 80

try:
    with socket.create_connection((parsed.hostname, port), timeout=2.0):
        pass
except OSError:
    print("missing")
else:
    print("available")
PY
}

is_available() {
  [[ "$1" == "available" ]]
}

missing_reasons_for_check() {
  local check_id="$1"
  local reasons=()

  case "$check_id" in
    ui-settings-backend)
      is_available "$ACCESSIBILITY_STATUS" || reasons+=("Accessibility=$ACCESSIBILITY_STATUS")
      is_available "$APPLE_EVENTS_STATUS" || reasons+=("AppleEvents=$APPLE_EVENTS_STATUS")
      is_available "$BACKEND_STATUS" || reasons+=("backend=$BACKEND_STATUS")
      ;;
    ui-inline-preview)
      is_available "$ACCESSIBILITY_STATUS" || reasons+=("Accessibility=$ACCESSIBILITY_STATUS")
      is_available "$INPUT_MONITORING_STATUS" || reasons+=("InputMonitoring=$INPUT_MONITORING_STATUS")
      is_available "$APPLE_EVENTS_STATUS" || reasons+=("AppleEvents=$APPLE_EVENTS_STATUS")
      ;;
    ui-playground)
      is_available "$ACCESSIBILITY_STATUS" || reasons+=("Accessibility=$ACCESSIBILITY_STATUS")
      is_available "$APPLE_EVENTS_STATUS" || reasons+=("AppleEvents=$APPLE_EVENTS_STATUS")
      ;;
  esac

  if [[ "${#reasons[@]}" -eq 0 ]]; then
    printf 'available\n'
  else
    local joined=""
    local reason
    for reason in "${reasons[@]}"; do
      if [[ -z "$joined" ]]; then
        joined="$reason"
      else
        joined="$joined; $reason"
      fi
    done
    printf '%s\n' "$joined"
  fi
}

cleanup_ui_processes() {
  pkill -x AutoComp >/dev/null 2>&1 || true
  pkill -x TextEdit >/dev/null 2>&1 || true
}

run_ui_check() {
  local check_id="$1"
  local display_name="$2"
  shift 2

  local missing
  missing="$(missing_reasons_for_check "$check_id")"
  if [[ "$missing" != "available" ]]; then
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
    append_result check "$check_id" "SKIPPED" "n/a" "$missing"
    return 0
  fi

  local log_path="$LOG_DIR/$(slug "$check_id").log"
  printf 'ci_ui_optional: running %s\n' "$display_name"
  "$@" >"$log_path" 2>&1
  local status=$?
  redact_log_file "$log_path"
  cleanup_ui_processes

  if [[ "$status" -eq 0 ]]; then
    append_result check "$check_id" "PASSED" "$log_path" "$display_name"
  else
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    append_result check "$check_id" "FAILED" "$log_path" "$display_name failed with exit status $status"
  fi
}

cd "$ROOT_DIR" || exit 1

printf 'section\tid\tstatus\tevidence\tnote\n' >"$RESULTS_PATH"

ACCESSIBILITY_STATUS="$(detect_accessibility)"
INPUT_MONITORING_STATUS="$(detect_input_monitoring)"
APPLE_EVENTS_STATUS="$(detect_apple_events)"
BACKEND_STATUS="$(detect_backend)"

append_result prerequisite "Accessibility" "$ACCESSIBILITY_STATUS" "n/a" "AXIsProcessTrusted"
append_result prerequisite "Input Monitoring" "$INPUT_MONITORING_STATUS" "n/a" "CGPreflightListenEventAccess"
append_result prerequisite "AppleEvents" "$APPLE_EVENTS_STATUS" "n/a" "System Events automation"
append_result prerequisite "Backend" "$BACKEND_STATUS" "$BACKEND_URL" "TCP preflight"

run_ui_check \
  ui-settings-backend \
  "settings/backend UI smoke" \
  "$SMOKE_SCRIPT_DIR/ui_smoke_test.sh"

if [[ "$SAFE_OVERLAY_MODE" == "1" ]]; then
  run_ui_check \
    ui-inline-preview \
    "inline preview UI smoke safe overlay mode" \
    env AUTOCOMP_SAFE_OVERLAY_MODE=1 "$SMOKE_SCRIPT_DIR/ui_inline_preview_smoke_test.sh" --safe-overlay-mode
else
  run_ui_check \
    ui-inline-preview \
    "inline preview UI smoke" \
    "$SMOKE_SCRIPT_DIR/ui_inline_preview_smoke_test.sh"
fi

run_ui_check \
  ui-playground \
  "model playground UI smoke" \
  "$SMOKE_SCRIPT_DIR/ui_playground_smoke_test.sh"

if [[ "$FAILED_CHECKS" -gt 0 ]]; then
  EXIT_STATUS=1
elif [[ "$SKIPPED_CHECKS" -gt 0 && "$ALLOW_SKIP" == "0" ]]; then
  EXIT_STATUS=1
else
  EXIT_STATUS=0
fi

if [[ "$EXIT_STATUS" -ne 0 && "$FAILED_CHECKS" -eq 0 && "$SKIPPED_CHECKS" -gt 0 ]]; then
  printf 'ci_ui_optional: missing required UI prerequisites; rerun with --allow-skip to record skips without failing\n' >&2
fi

{
  printf '# AutoComp Optional UI CI Run\n\n'
  printf -- '- Run ID: %s\n' "$RUN_ID"
  printf -- '- Timestamp UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- Host: %s\n' "$(hostname)"
  printf -- '- Workspace: %s\n' "$ROOT_DIR"
  printf -- '- Mode: %s\n' "$([[ "$ALLOW_SKIP" == "1" ]] && printf 'allow-skip' || printf 'strict')"
  printf -- '- Backend URL: %s\n' "$BACKEND_URL"
  printf -- '- Results TSV: %s\n\n' "$RESULTS_PATH"
  printf '## Detected Prerequisites\n\n'
  printf '| Prerequisite | Status | Note |\n'
  printf '| --- | --- | --- |\n'
  awk -F '\t' 'NR > 1 && $1 == "prerequisite" { printf "| %s | %s | %s |\n", $2, $3, $5 }' "$RESULTS_PATH"
  printf '\n## UI Checks\n\n'
  printf '| Check | Status | Evidence | Note |\n'
  printf '| --- | --- | --- | --- |\n'
  awk -F '\t' 'NR > 1 && $1 == "check" { printf "| %s | %s | `%s` | %s |\n", $2, $3, $4, $5 }' "$RESULTS_PATH"
  printf '\nSkipped checks in allow-skip mode are evidence that the host is not prepared for optional UI automation, not proof that the UI behavior passed.\n'
} >"$REPORT_PATH"

if [[ "$FAILED_CHECKS" -gt 0 ]]; then
  OVERALL_STATUS="FAILED"
elif [[ "$SKIPPED_CHECKS" -gt 0 && "$ALLOW_SKIP" == "0" ]]; then
  OVERALL_STATUS="FAILED"
elif [[ "$SKIPPED_CHECKS" -gt 0 ]]; then
  OVERALL_STATUS="SKIPPED"
else
  OVERALL_STATUS="PASSED"
fi

printf 'UI optional status: %s\n' "$OVERALL_STATUS"
printf 'UI optional report: %s\n' "$REPORT_PATH"
printf 'UI optional results: %s\n' "$RESULTS_PATH"
exit "$EXIT_STATUS"
