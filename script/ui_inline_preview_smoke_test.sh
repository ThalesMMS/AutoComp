#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SAFE_OVERLAY_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --safe-overlay-mode)
      SAFE_OVERLAY_MODE=1
      shift
      ;;
    -h|--help)
      echo "usage: ui_inline_preview_smoke_test.sh [--safe-overlay-mode]" >&2
      exit 0
      ;;
    *)
      echo "usage: ui_inline_preview_smoke_test.sh [--safe-overlay-mode]" >&2
      exit 2
      ;;
  esac
done

LOG_FILE="/tmp/autocomp_inline_preview_geometry.log"
rm -f "$LOG_FILE"

if [[ "$SAFE_OVERLAY_MODE" == "1" ]]; then
  AUTOCOMP_SAFE_OVERLAY_MODE=1 ./script/build_and_run.sh --ui-test-inline-preview >/tmp/autocomp_inline_preview_launch.log
else
  ./script/build_and_run.sh --ui-test-inline-preview >/tmp/autocomp_inline_preview_launch.log
fi

printf '' >/tmp/autocomp-inline-preview-smoke.txt
/usr/bin/open -a TextEdit /tmp/autocomp-inline-preview-smoke.txt
sleep 1
osascript -e 'tell application "System Events" to keystroke "Vamos tentar ver se"'
osascript -e 'tell application "System Events" to key code 49'
sleep 2
if [[ "$SAFE_OVERLAY_MODE" == "1" ]]; then
  osascript -e 'tell application "System Events" to key code 48'
  sleep 1
fi

# Controlled FIM case: create a suffix in TextEdit, move the caret before it,
# trigger manually, and verify logs record a non-empty suffix completion.
osascript -e 'tell application "System Events" to keystroke "a" using command down'
osascript -e 'tell application "System Events" to keystroke "A reuniao porque o prazo mudou."'
osascript <<'OSA'
tell application "System Events"
  repeat 21 times
    key code 123
  end repeat
  key code 49 using option down
end tell
OSA
sleep 2
pkill -x TextEdit >/dev/null 2>&1 || true
rm -f /tmp/autocomp-inline-preview-smoke.txt

/usr/bin/log show --last 30s \
  --info \
  --predicate 'process == "AutoComp" AND eventMessage CONTAINS "AutoCompGeometry"' \
  --style compact >"$LOG_FILE"

if grep -q 'Accessibility permission is required' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "AutoComp does not have Accessibility permission; inline preview smoke cannot inspect text metrics" >&2
  exit 1
fi

if [[ "$SAFE_OVERLAY_MODE" == "1" ]]; then
  if ! grep -q 'safe-overlay-mode active feature=preview-tier' "$LOG_FILE"; then
    cat "$LOG_FILE" >&2
    echo "safe overlay smoke did not log safe mode activation" >&2
    exit 1
  fi

  if grep -Eq 'resolvedTier=visualInlineOverlay|tier=visualInlineOverlay .* panel=' "$LOG_FILE"; then
    cat "$LOG_FILE" >&2
    echo "safe overlay smoke unexpectedly used visual inline overlay" >&2
    exit 1
  fi

  if ! grep -Eq 'resolvedTier=(simpleCaretPopup|mirrorWindow)|tier=simpleCaretPopup' "$LOG_FILE"; then
    cat "$LOG_FILE" >&2
    echo "safe overlay smoke did not use simple popup or mirror window" >&2
    exit 1
  fi

  if ! grep -Eq 'acceptance accepted action=next-word|shortcut-repair action=replace-leaked-tab' "$LOG_FILE"; then
    cat "$LOG_FILE" >&2
    echo "safe overlay smoke did not accept with Tab" >&2
    exit 1
  fi
elif grep -q 'resolvedTier=mirrorWindow' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview unexpectedly resolved to mirrorWindow" >&2
  exit 1
elif ! grep -q 'tier=visualInlineOverlay .* panel=' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview did not produce a visual inline overlay" >&2
  exit 1
fi

if [[ "$SAFE_OVERLAY_MODE" != "1" ]] && ! grep -Eq 'completion-success context=.*suffixLen=[1-9][0-9]*' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview FIM smoke did not record a non-empty suffix completion" >&2
  exit 1
fi

if grep -q 'panel-outside-visible-frame\|zero-origin\|outside-screen' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview geometry logged a rejected screen/corner metric" >&2
  exit 1
fi

echo "AutoComp inline preview smoke test passed"
