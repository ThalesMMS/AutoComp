#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_FILE="/tmp/autocomp_inline_preview_geometry.log"
rm -f "$LOG_FILE"

./script/build_and_run.sh --ui-test-inline-preview >/tmp/autocomp_inline_preview_launch.log

printf '' >/tmp/autocomp-inline-preview-smoke.txt
/usr/bin/open -a TextEdit /tmp/autocomp-inline-preview-smoke.txt
sleep 1
osascript -e 'tell application "System Events" to keystroke "Vamos tentar ver se"'
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

if grep -q 'resolvedTier=mirrorWindow' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview unexpectedly resolved to mirrorWindow" >&2
  exit 1
fi

if ! grep -q 'tier=visualInlineOverlay .* panel=' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview did not produce a visual inline overlay" >&2
  exit 1
fi

if grep -q 'panel-outside-visible-frame\|zero-origin\|outside-screen' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  echo "inline preview geometry logged a rejected screen/corner metric" >&2
  exit 1
fi

echo "AutoComp inline preview smoke test passed"
