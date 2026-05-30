#!/usr/bin/env bash
set -euo pipefail

# Clean-account install verification helper.
# This does NOT attempt to automate UI prompts; it runs command-line checks
# to confirm signing/notarization signals and provides manual next steps.

SCRIPT_NAME="$(basename "$0")"

print_help() {
  cat <<EOF
$SCRIPT_NAME — clean-account install verification helper

Usage:
  $SCRIPT_NAME --app /Applications/AutoComp.app
  $SCRIPT_NAME --dmg /path/to/AutoComp.dmg [--mount-point /Volumes/AutoComp]

What it does:
  - Runs spctl assessment for Gatekeeper status
  - Validates stapled notarization ticket (xcrun stapler validate)
  - Prints quarantine xattr (if present)
  - Optionally mounts a DMG and verifies the app inside it

Exit codes:
  0  All requested checks passed
  2  Invalid arguments / missing prereqs
  5  Gatekeeper assessment failed
  6  Stapler validation failed

Notes:
  - For full clean-account testing, follow Docs/CleanInstallVerification.md
  - This script never prints secret values.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

APP_PATH=""
DMG_PATH=""
MOUNT_POINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --app)
      APP_PATH="${2:-}"; shift 2
      ;;
    --dmg)
      DMG_PATH="${2:-}"; shift 2
      ;;
    --mount-point)
      MOUNT_POINT="${2:-}"; shift 2
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

require_command spctl
require_command xattr
require_command xcrun

run_checks_for_app() {
  local app="$1"

  [[ -e "$app" ]] || fail "App not found: $app"

  echo "== Gatekeeper assessment =="
  if spctl -a -vv "$app"; then
    echo "PASS: spctl assessment OK"
  else
    echo "FAIL: spctl assessment failed"
    exit 5
  fi

  echo
  echo "== Stapler validation =="
  if xcrun stapler validate "$app"; then
    echo "PASS: stapler validate OK"
  else
    echo "FAIL: stapler validate failed"
    exit 6
  fi

  echo
  echo "== Quarantine xattr (diagnostic) =="
  if xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then
    xattr -p com.apple.quarantine "$app" || true
  else
    echo "(no com.apple.quarantine attribute present)"
  fi
}

if [[ -n "$DMG_PATH" ]]; then
  [[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"
  require_command hdiutil

  echo "Mounting DMG (read-only): $DMG_PATH"

  # If mount point not specified, try to derive it from the volume name.
  # We will parse the mount output to get the actual mount point.
  ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>/dev/null || true)"
  [[ -n "$ATTACH_OUTPUT" ]] || fail "Failed to mount DMG"

  ACTUAL_MOUNT="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $NF; exit 0}')"
  [[ -n "$ACTUAL_MOUNT" ]] || fail "Could not determine DMG mount point"

  if [[ -n "$MOUNT_POINT" && "$MOUNT_POINT" != "$ACTUAL_MOUNT" ]]; then
    echo "WARN: requested mount point '$MOUNT_POINT' differs from actual '$ACTUAL_MOUNT'"
  fi

  DMG_APP="$ACTUAL_MOUNT/AutoComp.app"
  echo
  echo "Verifying app inside DMG: $DMG_APP"
  run_checks_for_app "$DMG_APP"

  echo
  echo "Detaching DMG: $ACTUAL_MOUNT"
  hdiutil detach "$ACTUAL_MOUNT" >/dev/null 2>&1 || true
  exit 0
fi

if [[ -n "$APP_PATH" ]]; then
  run_checks_for_app "$APP_PATH"
  exit 0
fi

print_help
exit 2
