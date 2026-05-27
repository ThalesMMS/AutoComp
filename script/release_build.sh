#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AutoComp"
BUNDLE_ID="com.autocomp.AutoComp"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

VERSION=""
BUILD_NUMBER=""
DRY_RUN=0
SKIP_NOTARIZE=0
SKIP_APPCAST=0
SIGNING_IDENTITY="${AUTOCOMP_RELEASE_SIGNING_IDENTITY:-${AUTOCOMP_CODESIGN_IDENTITY:-}}"
NOTARY_PROFILE="${AUTOCOMP_NOTARY_PROFILE:-}"
DOWNLOAD_URL="${AUTOCOMP_RELEASE_DOWNLOAD_URL:-}"
RELEASE_NOTES_URL="${AUTOCOMP_RELEASE_NOTES_URL:-}"
SPARKLE_FEED_URL="${AUTOCOMP_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${AUTOCOMP_SPARKLE_PUBLIC_KEY:-}"
SPARKLE_SIGN_UPDATE="${AUTOCOMP_SPARKLE_SIGN_UPDATE:-}"
SPARKLE_PRIVATE_KEY_FILE="${AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE:-}"
SPARKLE_VERSION="${AUTOCOMP_SPARKLE_VERSION:-2.9.2}"
SPARKLE_ARCHIVE_URL="${AUTOCOMP_SPARKLE_ARCHIVE_URL:-https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip}"
SPARKLE_ARCHIVE_CHECKSUM="${AUTOCOMP_SPARKLE_ARCHIVE_CHECKSUM:-b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65}"
SPARKLE_CACHE_DIR="${AUTOCOMP_SPARKLE_CACHE_DIR:-$ROOT_DIR/.build/sparkle-release}"
SPARKLE_FRAMEWORK_PATH="${AUTOCOMP_SPARKLE_FRAMEWORK_PATH:-}"
SPARKLE_EXTRACT_DIR=""
SPARKLE_FRAMEWORK_RESOLVED=""
SPARKLE_SIGN_UPDATE_RESOLVED=""

usage() {
  cat >&2 <<'USAGE'
usage: release_build.sh --version 1.0.0 --build 100 [options]

Options:
  --dry-run                 Print and validate the release plan without building or signing.
  --output-dir PATH         Release output directory. Defaults to dist/release.
  --download-url URL        Public DMG URL used in appcast.xml.
  --release-notes-url URL   Public release notes URL used in appcast.xml.
  --skip-notarize           Build and sign locally, but do not submit to notarytool.
  --skip-appcast            Do not generate appcast.xml.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
      APP_CONTENTS="$APP_BUNDLE/Contents"
      APP_MACOS="$APP_CONTENTS/MacOS"
      APP_RESOURCES="$APP_CONTENTS/Resources"
      APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
      APP_BINARY="$APP_MACOS/$APP_NAME"
      INFO_PLIST="$APP_CONTENTS/Info.plist"
      DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
      APPCAST_PATH="$OUTPUT_DIR/appcast.xml"
      shift 2
      ;;
    --download-url)
      DOWNLOAD_URL="${2:-}"
      shift 2
      ;;
    --release-notes-url)
      RELEASE_NOTES_URL="${2:-}"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --skip-appcast)
      SKIP_APPCAST=1
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

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  usage
  exit 2
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
  DOWNLOAD_URL="https://github.com/ThalesMMS/AutoComp-dev/releases/download/v$VERSION/$APP_NAME.dmg"
fi

if [[ -z "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_URL="https://github.com/ThalesMMS/AutoComp-dev/releases/tag/v$VERSION"
fi

case "$OUTPUT_DIR" in
  ""|"/"|".")
    echo "Refusing unsafe release output directory: $OUTPUT_DIR" >&2
    exit 1
    ;;
esac

require_non_empty() {
  local value="$1"
  local message="$2"
  if [[ -z "$value" ]]; then
    echo "$message" >&2
    exit 1
  fi
}

run_dry_plan() {
  cat <<PLAN
Release dry run:
+ swift build -c release --product "$APP_NAME"
+ stage "$APP_BUNDLE" with version "$VERSION" build "$BUILD_NUMBER"
+ fetch Sparkle "$SPARKLE_VERSION" from "$SPARKLE_ARCHIVE_URL" unless AUTOCOMP_SPARKLE_FRAMEWORK_PATH is set
+ embed Sparkle.framework in "$APP_FRAMEWORKS"
+ add SUFeedURL and SUPublicEDKey to "$INFO_PLIST"
+ codesign --force --deep --options runtime --sign "\${AUTOCOMP_RELEASE_SIGNING_IDENTITY}" "$APP_BUNDLE"
+ script/release_dmg.sh --app-path "$APP_BUNDLE" --output-path "$DMG_PATH" --volume-name "$APP_NAME"
+ xcrun notarytool submit "$DMG_PATH" --keychain-profile "\${AUTOCOMP_NOTARY_PROFILE}" --wait
+ xcrun stapler staple "$DMG_PATH"
+ script/release_appcast.py --version "$VERSION" --build "$BUILD_NUMBER" --archive "$DMG_PATH" --download-url "$DOWNLOAD_URL" --release-notes-url "$RELEASE_NOTES_URL" --output "$APPCAST_PATH"
PLAN

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "Dry-run note: AUTOCOMP_RELEASE_SIGNING_IDENTITY is not set."
  fi
  if [[ "$SKIP_NOTARIZE" == "0" && -z "$NOTARY_PROFILE" ]]; then
    echo "Dry-run note: AUTOCOMP_NOTARY_PROFILE is not set."
  fi
  if [[ "$SKIP_APPCAST" == "0" && -z "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    echo "Dry-run note: AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE is not set; sign_update may use Keychain locally."
  fi
  if [[ -z "$SPARKLE_FEED_URL" ]]; then
    echo "Dry-run note: AUTOCOMP_SPARKLE_FEED_URL is not set."
  fi
  if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "Dry-run note: AUTOCOMP_SPARKLE_PUBLIC_KEY is not set."
  fi

  "$ROOT_DIR/script/release_dmg.sh" \
    --dry-run \
    --app-path "$APP_BUNDLE" \
    --output-path "$DMG_PATH" \
    --volume-name "$APP_NAME"

  if [[ "$SKIP_APPCAST" == "0" ]]; then
    python3 "$ROOT_DIR/script/release_appcast.py" \
      --dry-run \
      --version "$VERSION" \
      --build "$BUILD_NUMBER" \
      --archive "$DMG_PATH" \
      --download-url "$DOWNLOAD_URL" \
      --release-notes-url "$RELEASE_NOTES_URL" \
      --output "$APPCAST_PATH"
  fi
}

copy_sparkle_framework() {
  prepare_sparkle_package
  mkdir -p "$APP_FRAMEWORKS"
  /usr/bin/ditto "$SPARKLE_FRAMEWORK_RESOLVED" "$APP_FRAMEWORKS/Sparkle.framework"
}

prepare_sparkle_package() {
  if [[ -n "$SPARKLE_FRAMEWORK_RESOLVED" ]]; then
    return
  fi

  if [[ -n "$SPARKLE_FRAMEWORK_PATH" ]]; then
    if [[ ! -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
      echo "Sparkle framework not found: $SPARKLE_FRAMEWORK_PATH" >&2
      exit 1
    fi
    SPARKLE_FRAMEWORK_RESOLVED="$SPARKLE_FRAMEWORK_PATH"
    return
  fi

  local archive
  archive="$(download_sparkle_archive)"
  SPARKLE_EXTRACT_DIR="$SPARKLE_CACHE_DIR/Sparkle-$SPARKLE_VERSION"
  if [[ ! -d "$SPARKLE_EXTRACT_DIR/Sparkle.xcframework" ]]; then
    rm -rf "$SPARKLE_EXTRACT_DIR"
    mkdir -p "$SPARKLE_EXTRACT_DIR"
    /usr/bin/ditto -x -k "$archive" "$SPARKLE_EXTRACT_DIR"
  fi

  SPARKLE_FRAMEWORK_RESOLVED="$(find "$SPARKLE_EXTRACT_DIR/Sparkle.xcframework" -path "*/Sparkle.framework" -type d -print -quit 2>/dev/null || true)"
  if [[ -z "$SPARKLE_FRAMEWORK_RESOLVED" ]]; then
    echo "Sparkle.framework not found in $archive." >&2
    exit 1
  fi

  SPARKLE_SIGN_UPDATE_RESOLVED="$SPARKLE_EXTRACT_DIR/bin/sign_update"
}

download_sparkle_archive() {
  mkdir -p "$SPARKLE_CACHE_DIR"
  local archive="$SPARKLE_CACHE_DIR/Sparkle-$SPARKLE_VERSION.zip"
  if [[ ! -f "$archive" ]]; then
    curl -L --fail --output "$archive" "$SPARKLE_ARCHIVE_URL"
  fi

  local checksum
  checksum="$(swift package compute-checksum "$archive")"
  if [[ "$checksum" != "$SPARKLE_ARCHIVE_CHECKSUM" ]]; then
    rm -f "$archive"
    echo "Sparkle archive checksum mismatch for $SPARKLE_ARCHIVE_URL" >&2
    echo "Expected: $SPARKLE_ARCHIVE_CHECKSUM" >&2
    echo "Actual:   $checksum" >&2
    exit 1
  fi

  printf '%s\n' "$archive"
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>AutoComp reads the active browser tab URL locally to apply per-domain compatibility and privacy rules.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>AutoComp connects to your configured autocomplete backend on the local network when you use a LAN endpoint.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
  <key>NSScreenCaptureUsageDescription</key>
  <string>AutoComp can optionally use visible on-screen text as autocomplete context.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>AutoComp uses Tab and backtick as global shortcuts to accept autocomplete suggestions.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 AutoComp.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  if [[ -n "$SPARKLE_FEED_URL" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$INFO_PLIST"
  fi
  if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$INFO_PLIST"
  fi
}

if [[ "$DRY_RUN" == "1" ]]; then
  run_dry_plan
  exit 0
fi

require_non_empty "$SIGNING_IDENTITY" "Set AUTOCOMP_RELEASE_SIGNING_IDENTITY to a Developer ID Application identity."
require_non_empty "$SPARKLE_FEED_URL" "Set AUTOCOMP_SPARKLE_FEED_URL so release builds can check the appcast."
require_non_empty "$SPARKLE_PUBLIC_KEY" "Set AUTOCOMP_SPARKLE_PUBLIC_KEY to the Sparkle Ed25519 public key."
if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  require_non_empty "$NOTARY_PROFILE" "Set AUTOCOMP_NOTARY_PROFILE to a notarytool keychain profile, or pass --skip-notarize."
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"

swift build -c release --product "$APP_NAME"
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
copy_sparkle_framework

if [[ -d "$ROOT_DIR/Resources" ]]; then
  rsync -a --delete "$ROOT_DIR/Resources/" "$APP_RESOURCES/Resources/"
fi

write_info_plist

/usr/bin/codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework"
/usr/bin/codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

"$ROOT_DIR/script/release_dmg.sh" \
  --app-path "$APP_BUNDLE" \
  --output-path "$DMG_PATH" \
  --volume-name "$APP_NAME"

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
else
  echo "Skipped notarization for $DMG_PATH"
fi

if [[ "$SKIP_APPCAST" == "0" ]]; then
  if [[ -z "$SPARKLE_SIGN_UPDATE" && -x "$SPARKLE_SIGN_UPDATE_RESOLVED" ]]; then
    SPARKLE_SIGN_UPDATE="$SPARKLE_SIGN_UPDATE_RESOLVED"
  fi

  APPCAST_ARGS=(
    --version "$VERSION"
    --build "$BUILD_NUMBER"
    --archive "$DMG_PATH"
    --download-url "$DOWNLOAD_URL"
    --release-notes-url "$RELEASE_NOTES_URL"
    --output "$APPCAST_PATH"
  )
  if [[ -n "$SPARKLE_SIGN_UPDATE" ]]; then
    APPCAST_ARGS+=(--sign-update-tool "$SPARKLE_SIGN_UPDATE")
  fi
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    APPCAST_ARGS+=(--private-key-file "$SPARKLE_PRIVATE_KEY_FILE")
  fi
  python3 "$ROOT_DIR/script/release_appcast.py" "${APPCAST_ARGS[@]}"
fi

echo "Release artifacts written to: $OUTPUT_DIR"
