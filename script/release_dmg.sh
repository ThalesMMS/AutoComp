#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME="AutoComp"
DRY_RUN=0

usage() {
  cat >&2 <<'USAGE'
usage: release_dmg.sh --app-path AutoComp.app --output-path AutoComp.dmg [--volume-name AutoComp] [--dry-run]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --output-path)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

if [[ -z "$APP_PATH" || -z "$OUTPUT_PATH" ]]; then
  usage
  exit 2
fi

APP_BASENAME="$(basename "$APP_PATH")"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<DRYRUN
Release DMG dry run:
+ create temporary staging directory
+ ditto "$APP_PATH" "\$STAGING_ROOT/$APP_BASENAME"
+ ln -s /Applications "\$STAGING_ROOT/Applications"
+ hdiutil create -volname "$VOLUME_NAME" -srcfolder "\$STAGING_ROOT" -ov -format UDZO "$OUTPUT_PATH"
DRYRUN
  exit 0
fi

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/autocomp-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT

/usr/bin/ditto "$APP_PATH" "$STAGING_ROOT/$APP_BASENAME"
ln -s /Applications "$STAGING_ROOT/Applications"
rm -f "$OUTPUT_PATH"
/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_ROOT" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"

echo "Created DMG: $OUTPUT_PATH"
