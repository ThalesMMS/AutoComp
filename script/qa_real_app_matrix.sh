#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${AUTOCOMP_QA_OUTPUT_DIR:-$ROOT_DIR/dist/qa}"
RUN_SWIFT_TEST=1
RUN_UI=1
ALLOW_UI_FAILURES=0
SAFE_OVERLAY_MODE=0
SKIP_REASON=""
REDACT_ONLY_PATH=""

usage() {
  cat >&2 <<'USAGE'
usage: qa_real_app_matrix.sh [options]

Options:
  --output-dir PATH       Directory for the Markdown report and command logs.
  --skip-swift-test       Record swift test as skipped.
  --skip-ui               Record both UI smoke scripts as skipped.
  --reason TEXT           Required with --skip-ui; explains why UI smoke was skipped.
  --allow-ui-failures     Keep exit status 0 while recording UI smoke failures.
  --safe-overlay-mode     Run inline preview smoke with AUTOCOMP_SAFE_OVERLAY_MODE=1.
  --redact-log PATH       Redact an existing command log and exit.
USAGE
}

redact_log_file() {
  local log_path="$1"
  [[ -f "$log_path" ]] || return 0

  python3 - "$log_path" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
text = re.sub(
    r"<visual_context>.*?</visual_context>",
    "<visual_context>\n[redacted visual context]\n</visual_context>",
    text,
    flags=re.DOTALL,
)

sensitive_labels = {
    "Text before cursor:",
    "Text before cursor (prefix):",
    "Text after cursor (suffix):",
    "Selected text to replace:",
    "Clipboard context:",
    "Prompt:",
    "Raw output:",
    "Normalized output:",
    "Completion:",
    "<|fim_prefix|>",
    "<|fim_suffix|>",
}
boundary_labels = sensitive_labels | {
    "FIM suffix injected:",
    "<|fim_middle|>",
    "</visual_context>",
}

lines = text.splitlines(keepends=True)
redacted = []
index = 0
while index < len(lines):
    stripped = lines[index].rstrip("\r\n")
    if stripped in sensitive_labels:
        redacted.append(lines[index])
        redacted.append("[redacted]\n")
        index += 1
        while index < len(lines):
            candidate = lines[index].rstrip("\r\n")
            if candidate in boundary_labels:
                break
            index += 1
        continue

    redacted.append(lines[index])
    index += 1

path.write_text("".join(redacted), encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --skip-swift-test)
      RUN_SWIFT_TEST=0
      shift
      ;;
    --skip-ui)
      RUN_UI=0
      shift
      ;;
    --reason)
      SKIP_REASON="${2:-}"
      shift 2
      ;;
    --allow-ui-failures)
      ALLOW_UI_FAILURES=1
      shift
      ;;
    --safe-overlay-mode)
      SAFE_OVERLAY_MODE=1
      shift
      ;;
    --redact-log)
      REDACT_ONLY_PATH="${2:-}"
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

if [[ -n "$REDACT_ONLY_PATH" ]]; then
  redact_log_file "$REDACT_ONLY_PATH"
  exit 0
fi

if [[ "$RUN_UI" == "0" && -z "$SKIP_REASON" ]]; then
  echo "--reason is required when --skip-ui is used" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_PATH="$OUTPUT_DIR/qa-run-$RUN_ID.md"
EXIT_STATUS=0

cleanup_ui_processes() {
  pkill -x AutoComp >/dev/null 2>&1 || true
  pkill -x TextEdit >/dev/null 2>&1 || true
}

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-'
}

append_result() {
  local name="$1"
  local status="$2"
  local evidence="$3"
  local note="$4"

  {
    printf '| %s | %s | %s | %s |\n' "$name" "$status" "$evidence" "$note"
  } >>"$REPORT_PATH"
}

run_step() {
  local kind="$1"
  local name="$2"
  shift 2

  local log_path="$OUTPUT_DIR/$(slug "$name").log"
  if "$@" >"$log_path" 2>&1; then
    redact_log_file "$log_path"
    append_result "$name" "PASSED" "$log_path" "Executed"
  else
    local code=$?
    redact_log_file "$log_path"
    append_result "$name" "FAILED" "$log_path" "Exit code $code"
    if [[ "$kind" == "ui" ]]; then
      cleanup_ui_processes
      if [[ "$ALLOW_UI_FAILURES" == "0" ]]; then
        EXIT_STATUS=1
      fi
    else
      EXIT_STATUS=1
    fi
  fi
}

cd "$ROOT_DIR"

cat >"$REPORT_PATH" <<REPORT
# AutoComp Real-App QA Run

- Run ID: $RUN_ID
- Host: $(hostname)
- Workspace: $ROOT_DIR

| Check | Status | Evidence | Note |
| --- | --- | --- | --- |
REPORT

if [[ "$RUN_SWIFT_TEST" == "1" ]]; then
  run_step core "swift test" swift test
else
  append_result "swift test" "SKIPPED" "n/a" "Skipped by operator"
fi

if [[ "$RUN_UI" == "1" ]]; then
  if [[ "$SAFE_OVERLAY_MODE" == "1" ]]; then
    run_step ui "ui inline preview smoke safe mode" ./script/ui_inline_preview_smoke_test.sh --safe-overlay-mode
  else
    run_step ui "ui inline preview smoke" ./script/ui_inline_preview_smoke_test.sh
  fi
  cleanup_ui_processes
  run_step ui "ui settings backend smoke" ./script/ui_smoke_test.sh
  cleanup_ui_processes
else
  append_result "ui inline preview smoke" "SKIPPED" "n/a" "$SKIP_REASON"
  append_result "ui settings backend smoke" "SKIPPED" "n/a" "$SKIP_REASON"
fi

cat >>"$REPORT_PATH" <<'REPORT'

Manual app coverage is defined in Docs/AppQAMatrix.md. Referenced command logs are redacted before attachment; keep local debug artifacts separate unless local debug opt-in was intentionally enabled. Record non-content source, quality, and trust labels for focused-text capture evidence; do not record typed text, OCR text, clipboard text, prompts, or completions.
REPORT

echo "QA report: $REPORT_PATH"
exit "$EXIT_STATUS"
