#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AutoComp"
BUNDLE_ID="com.autocomp.AutoComp"
HOME_DIR="$HOME"
DRY_RUN=0
SKIP_KEYCHAIN=0
EXTRA_APP_PATHS=()

usage() {
  cat >&2 <<'USAGE'
usage: uninstall.sh [options]

Options:
  --dry-run             Print the paths and keychain items that would be removed.
  --home PATH           Override the home directory root. Intended for tests.
  --app-path PATH       Remove an additional AutoComp.app path.
  --skip-keychain       Skip Keychain cleanup. Intended for tests.
  -h, --help            Show this help text.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --home)
      HOME_DIR="${2:-}"
      shift 2
      ;;
    --app-path)
      EXTRA_APP_PATHS+=("${2:-}")
      shift 2
      ;;
    --skip-keychain)
      SKIP_KEYCHAIN=1
      shift
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

case "$HOME_DIR" in
  ""|"/")
    echo "Refusing unsafe home directory: $HOME_DIR" >&2
    exit 1
    ;;
esac

APP_PATHS=(
  "/Applications/$APP_NAME.app"
  "$HOME_DIR/Applications/$APP_NAME.app"
)

if [[ "${#EXTRA_APP_PATHS[@]}" -gt 0 ]]; then
  for path in "${EXTRA_APP_PATHS[@]}"; do
    [[ -n "$path" ]] && APP_PATHS+=("$path")
  done
fi

APPLICATION_SUPPORT_PATH="$HOME_DIR/Library/Application Support/$APP_NAME"

STATE_PATHS=(
  "$APPLICATION_SUPPORT_PATH"
  "$HOME_DIR/Library/Caches/$BUNDLE_ID"
  "$HOME_DIR/Library/Caches/$APP_NAME"
  "$HOME_DIR/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME_DIR/Library/Logs/$APP_NAME"
  "$HOME_DIR/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME_DIR/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$HOME_DIR/Library/WebKit/$BUNDLE_ID"
  "$HOME_DIR/Library/Containers/$BUNDLE_ID"
  "$HOME_DIR/Library/Application Scripts/$BUNDLE_ID"
)

run_remove() {
  local path="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ rm -rf \"$path\""
  else
    rm -rf "$path"
    echo "Removed: $path"
  fi
}

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    run_remove "$path"
  else
    echo "Already absent: $path"
  fi
}

remove_keychain_item() {
  local service="$1"
  local account="$2"

  if [[ "$SKIP_KEYCHAIN" == "1" ]]; then
    echo "Skipping Keychain item: service=$service account=$account"
    return
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ security delete-generic-password -s \"$service\" -a \"$account\""
    return
  fi

  if security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
    echo "Removed Keychain item: service=$service account=$account"
  else
    echo "Keychain item absent or not accessible: service=$service account=$account"
  fi
}

if [[ "$DRY_RUN" == "1" ]]; then
  echo "AutoComp uninstall dry run"
else
  echo "Uninstalling AutoComp"
fi

for path in "${APP_PATHS[@]}"; do
  remove_path "$path"
done

for path in "${STATE_PATHS[@]}"; do
  remove_path "$path"
done

if [[ "$DRY_RUN" == "0" && -e "$APPLICATION_SUPPORT_PATH" ]]; then
  echo "Application Support cleanup failed: $APPLICATION_SUPPORT_PATH still exists." >&2
  exit 1
fi

remove_keychain_item "com.autocomp.backend" "remote-api-key"
remove_keychain_item "com.autocomp.personalization" "local-profile-key"

cat <<'NOTICE'
macOS permissions are not modified by this script.
For a full reset, remove AutoComp manually in System Settings > Privacy & Security for Accessibility, Input Monitoring, Screen Recording, Local Network, and Apple Events when present.
NOTICE
