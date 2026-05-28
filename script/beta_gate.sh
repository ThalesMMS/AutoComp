#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${AUTOCOMP_BETA_GATE_OUTPUT_DIR:-$ROOT_DIR/dist/release}"
SKIP_UI_REASON="${AUTOCOMP_BETA_GATE_UI_SKIP_REASON:-}"
SKIP_LLAMA_REASON="${AUTOCOMP_BETA_GATE_LLAMA_SKIP_REASON:-}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR=""
RESULTS_PATH=""
BETA_GATE_STATUS=0

usage() {
  cat >&2 <<'USAGE'
usage: beta_gate.sh [options]

Options:
  --output-dir PATH          Directory for beta-gate results and command logs.
  --skip-ui-smoke REASON     Record UI/backend smoke as skipped with a reason.
  --skip-llama-build REASON  Record llama build matrix as skipped with a reason.

Runs the blocking P0 beta readiness gate. Required headless, build, privacy, and
security checks fail the gate on failure and cannot be skipped. Conditional UI
and local-runtime checks may be skipped only with an explicit reason.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --skip-ui-smoke)
      SKIP_UI_REASON="${2:-}"
      shift 2
      ;;
    --skip-llama-build)
      SKIP_LLAMA_REASON="${2:-}"
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
    echo "Refusing unsafe beta-gate output directory: $OUTPUT_DIR" >&2
    exit 1
    ;;
esac

cd "$ROOT_DIR" || exit 1

LOG_DIR="$OUTPUT_DIR/beta-gate-logs-$RUN_ID"
RESULTS_PATH="$OUTPUT_DIR/beta-gate-results.tsv"

report() {
  printf 'beta-gate: %s\n' "$*"
}

tsv_escape() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

append_result() {
  local id="$1"
  local issue="$2"
  local requirement="$3"
  local status="$4"
  local evidence="$5"
  local note="$6"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(tsv_escape "$id")" \
    "$(tsv_escape "$issue")" \
    "$(tsv_escape "$requirement")" \
    "$(tsv_escape "$status")" \
    "$(tsv_escape "$evidence")" \
    "$(tsv_escape "$note")" >>"$RESULTS_PATH"
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
}

run_without_llama_env() (
  unset AUTOCOMP_ENABLE_LLAMA_RUNTIME
  unset AUTOCOMP_LLAMA_CFLAGS
  unset AUTOCOMP_LLAMA_LIBS
  "$@"
)

run_check() {
  local id="$1"
  local issue="$2"
  local requirement="$3"
  local label="$4"
  shift 4

  local log_path="$LOG_DIR/$(slug "$id").log"
  report "running $id $label"
  "$@" >"$log_path" 2>&1
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    append_result "$id" "$issue" "$requirement" "PASSED" "$log_path" "$label"
    report "passed $id"
  else
    append_result "$id" "$issue" "$requirement" "FAILED" "$log_path" "$label failed with exit status $status"
    report "FAILED $id exit=$status log=$log_path"
    BETA_GATE_STATUS=1
  fi
  return "$status"
}

skip_check() {
  local id="$1"
  local issue="$2"
  local reason="$3"

  append_result "$id" "$issue" "CONDITIONAL" "SKIPPED" "n/a" "skip_reason=$reason"
  report "skipped $id reason=$reason"
}

fail_missing_skip() {
  local id="$1"
  local issue="$2"
  local reason="$3"

  append_result "$id" "$issue" "CONDITIONAL" "FAILED" "n/a" "$reason"
  report "FAILED $id $reason"
  BETA_GATE_STATUS=1
}

llama_config_requested_or_available() {
  if [[ -n "${AUTOCOMP_ENABLE_LLAMA_RUNTIME:-}" || -n "${AUTOCOMP_LLAMA_CFLAGS:-}" || -n "${AUTOCOMP_LLAMA_LIBS:-}" ]]; then
    return 0
  fi

  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists llama
}

run_llama_gate() {
  local id="P0-#100-llama-build"
  if [[ -n "$SKIP_LLAMA_REASON" ]]; then
    skip_check "$id" "#100" "$SKIP_LLAMA_REASON"
    return
  fi

  if llama_config_requested_or_available; then
    run_check "$id" "#100" "CONDITIONAL" "Build with llama runtime" \
      "$ROOT_DIR/script/build_with_llama.sh"
  else
    fail_missing_skip "$id" "#100" "llama.cpp dependencies unavailable and --skip-llama-build was not provided"
  fi
}

run_ui_gate() {
  local id="P0-#106-ui-smoke"
  if [[ -n "$SKIP_UI_REASON" ]]; then
    skip_check "$id" "#106" "$SKIP_UI_REASON"
    return
  fi

  local log_path="$LOG_DIR/$(slug "$id").log"
  report "running $id permission-aware optional UI smoke"
  "$ROOT_DIR/script/ci_ui_optional.sh" \
    --allow-skip \
    --output-dir "$LOG_DIR/ui-optional" >"$log_path" 2>&1
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    append_result "$id" "#106,#107" "CONDITIONAL" "FAILED" "$log_path" "permission-aware optional UI smoke failed with exit status $status"
    report "FAILED $id exit=$status log=$log_path"
    BETA_GATE_STATUS=1
    return
  fi

  local results_path
  results_path="$(awk -F ': ' '/^UI optional results:/ { value=$2 } END { print value }' "$log_path")"
  local report_path
  report_path="$(awk -F ': ' '/^UI optional report:/ { value=$2 } END { print value }' "$log_path")"
  local skip_reasons
  skip_reasons=""
  if [[ -n "$results_path" && -f "$results_path" ]]; then
    skip_reasons="$(awk -F '\t' 'NR > 1 && $1 == "check" && $3 == "SKIPPED" { item=$2 "=" $5; if (out == "") { out=item } else { out=out "; " item } } END { print out }' "$results_path")"
  fi

  if [[ -n "$skip_reasons" ]]; then
    append_result "$id" "#106,#107" "CONDITIONAL" "SKIPPED" "$log_path" "skip_reason=$skip_reasons report=$report_path"
    report "skipped $id reason=$skip_reasons report=$report_path"
  else
    append_result "$id" "#106,#107" "CONDITIONAL" "PASSED" "$log_path" "permission-aware optional UI smoke report=$report_path"
    report "passed $id report=$report_path"
  fi
}

check_no_hardcoded_release_secrets() (
  cd "$ROOT_DIR" || exit 1
  python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
inputs = [
    root / "Sources",
    root / "script",
    root / "Docs",
    root / "README.md",
    root / "Package.swift",
]
patterns = [
    re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----"),
    re.compile(r"AUTOCOMP_REMOTE_API_KEY\s*=\s*[\"']?[A-Za-z0-9_-]{8,}"),
]
hits = []

for item in inputs:
    paths = [item] if item.is_file() else sorted(path for path in item.rglob("*") if path.is_file())
    for path in paths:
        if any(part.startswith(".") for part in path.relative_to(root).parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            if any(pattern.search(line) for pattern in patterns):
                hits.append(f"{path.relative_to(root)}:{line_number}: possible hardcoded secret")

if hits:
    print("\n".join(hits))
    sys.exit(1)
PY
)

mkdir -p "$LOG_DIR"
printf 'id\tissue\trequirement\tstatus\tevidence\tnote\n' >"$RESULTS_PATH"

report "results=$RESULTS_PATH"
report "logs=$LOG_DIR"

run_check "P0-#99-headless-ci" "#99,#106" "REQUIRED" "Headless CI gate" \
  "$ROOT_DIR/script/ci_headless.sh"
run_llama_gate
run_ui_gate
run_check "P0-#102-privacy-redaction" "#102" "REQUIRED" "Privacy redaction sentinels" \
  run_without_llama_env swift test --filter RedactionSentinelRegressionTests
run_check "P0-#103-delete-all-privacy-data" "#103" "REQUIRED" "Delete all local privacy data" \
  run_without_llama_env swift test --filter LocalPrivacyDataResetServiceTests
run_check "P0-#105-secure-field" "#105" "REQUIRED" "Secure-field regressions" \
  run_without_llama_env swift test --filter SecureField
run_check "P0-#101-startup-side-effects" "#101" "REQUIRED" "No startup side effects" \
  run_without_llama_env swift test --filter StartupPrivacyRegressionTests
run_check "P0-#106-hardcoded-secrets" "#106" "REQUIRED" "No hardcoded release secrets" \
  check_no_hardcoded_release_secrets
run_check "P0-#106-prompt-preview-opt-in" "#102,#106" "REQUIRED" "Prompt preview hidden without debug opt-in" \
  run_without_llama_env swift test --filter RedactionSentinelRegressionTests/testSensitiveDebugDisabledRedactsSentinelsAcrossNormalSurfaces

if [[ "$BETA_GATE_STATUS" -eq 0 ]]; then
  report "passed results=$RESULTS_PATH"
else
  report "FAILED results=$RESULTS_PATH"
fi

exit "$BETA_GATE_STATUS"
