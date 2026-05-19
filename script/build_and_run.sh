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
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

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
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

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

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_app_with_args() {
  /usr/bin/open -n "$APP_BUNDLE" --args "$@"
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
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--geometry-debug|--ui-test-settings|--ui-test-inline-preview|--ui-test-onboarding]" >&2
    exit 2
    ;;
esac
