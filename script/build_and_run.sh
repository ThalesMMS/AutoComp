#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AutoComp"
BUNDLE_ID="com.autocomp.AutoComp"
MIN_SYSTEM_VERSION="14.0"
SIGNING_IDENTITY="${AUTOCOMP_CODESIGN_IDENTITY:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SPARKLE_FEED_URL="${AUTOCOMP_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${AUTOCOMP_SPARKLE_PUBLIC_KEY:-}"
SPARKLE_FRAMEWORK_PATH="${AUTOCOMP_SPARKLE_FRAMEWORK_PATH:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
done < <(pgrep -x "$APP_NAME" || true)
sleep 0.2
while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
done < <(pgrep -x "$APP_NAME" || true)

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

copy_sparkle_framework() {
  local framework_path
  framework_path="$SPARKLE_FRAMEWORK_PATH"
  if [[ -z "$framework_path" ]]; then
    framework_path="$(find "$ROOT_DIR/.build" -path "*/Sparkle.framework" -type d -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$framework_path" ]]; then
    echo "Sparkle.framework not found. Set AUTOCOMP_SPARKLE_FRAMEWORK_PATH for local update testing." >&2
    exit 1
  fi
  /usr/bin/ditto "$framework_path" "$APP_FRAMEWORKS/Sparkle.framework"
}

if [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_KEY" || -n "$SPARKLE_FRAMEWORK_PATH" ]]; then
  if [[ -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "Set both AUTOCOMP_SPARKLE_FEED_URL and AUTOCOMP_SPARKLE_PUBLIC_KEY for local update testing." >&2
    exit 1
  fi
  copy_sparkle_framework
fi

if [[ -d "$ROOT_DIR/Resources" ]]; then
  rsync -a --delete "$ROOT_DIR/Resources/" "$APP_RESOURCES/Resources/"
fi

if [[ -f "$ROOT_DIR/.env.local" ]]; then
  cp "$ROOT_DIR/.env.local" "$APP_RESOURCES/autocomp.env"
fi

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

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_app_with_args() {
  local args=("$@")
  if [[ "${AUTOCOMP_SAFE_OVERLAY_MODE:-}" == "1" ]]; then
    args+=(--safe-overlay-mode)
  fi
  /usr/bin/open -n "$APP_BUNDLE" --args "${args[@]}"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --geometry-debug|geometry-debug)
    open_app_with_args --geometry-debug
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --ui-test-settings|ui-test-settings)
    open_app_with_args --ui-test-settings
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --ui-test-inline-preview|ui-test-inline-preview)
    open_app_with_args --ui-test-inline-preview --geometry-debug
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --ui-test-onboarding|ui-test-onboarding)
    open_app_with_args --ui-test-onboarding
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --ui-test-playground|ui-test-playground)
    open_app_with_args --ui-test-playground
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--geometry-debug|--ui-test-settings|--ui-test-inline-preview|--ui-test-onboarding|--ui-test-playground]" >&2
    exit 2
    ;;
esac
