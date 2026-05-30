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
CHECKLIST_PATH="$OUTPUT_DIR/release-checklist.md"
BETA_GATE_RESULTS_PATH="$OUTPUT_DIR/beta-gate-results.tsv"

VERSION=""
BUILD_NUMBER=""
DRY_RUN=0
BETA_GATE=0
BETA_GATE_ARGS=()
INCLUDE_LLAMA_RUNTIME=0
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
LLAMA_ORIGINAL_DYLIBS=()
LLAMA_BUNDLED_DYLIBS=()
PRESERVED_BETA_GATE_DIR=""

usage() {
  cat >&2 <<'USAGE'
usage: release_build.sh --version 1.0.0 --build 100 [options]

Options:
  --beta-gate               Run the P0 beta readiness gate and exit.
  --dry-run                 Print and validate the release plan without building or signing.
  --include-llama-runtime   Build and bundle the optional in-process llama runtime.
  --output-dir PATH         Release output directory. Defaults to dist/release.
  --download-url URL        Public DMG URL used in appcast.xml.
  --release-notes-url URL   Public release notes URL used in appcast.xml.
  --skip-notarize           Build and sign locally, but do not submit to notarytool.
  --skip-appcast            Do not generate appcast.xml.
  --skip-ui-smoke REASON    Beta gate only: structured UI smoke skip reason.
  --skip-llama-build REASON Beta gate only: structured local-runtime skip reason.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --beta-gate)
      BETA_GATE=1
      shift
      ;;
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
    --include-llama-runtime)
      INCLUDE_LLAMA_RUNTIME=1
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
      CHECKLIST_PATH="$OUTPUT_DIR/release-checklist.md"
      BETA_GATE_RESULTS_PATH="$OUTPUT_DIR/beta-gate-results.tsv"
      BETA_GATE_ARGS+=(--output-dir "$OUTPUT_DIR")
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
    --skip-ui-smoke)
      BETA_GATE_ARGS+=(--skip-ui-smoke "${2:-}")
      shift 2
      ;;
    --skip-llama-build)
      BETA_GATE_ARGS+=(--skip-llama-build "${2:-}")
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

if [[ "$BETA_GATE" == "1" ]]; then
  exec "$ROOT_DIR/script/beta_gate.sh" "${BETA_GATE_ARGS[@]}"
fi

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  usage
  exit 2
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
  DOWNLOAD_URL="https://github.com/ThalesMMS/AutoComp/releases/download/v$VERSION/$APP_NAME.dmg"
fi

if [[ -z "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_URL="https://github.com/ThalesMMS/AutoComp/releases/tag/v$VERSION"
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

generate_release_checklist() {
  local mode="$1"
  shift

  local checklist_args=(
    --output "$CHECKLIST_PATH"
    --output-dir "$OUTPUT_DIR"
    --version "$VERSION"
    --build "$BUILD_NUMBER"
    --mode "$mode"
    --beta-gate-results "$BETA_GATE_RESULTS_PATH"
    --app-bundle "$APP_BUNDLE"
    --dmg "$DMG_PATH"
    --appcast "$APPCAST_PATH"
    --download-url "$DOWNLOAD_URL"
    --release-notes-url "$RELEASE_NOTES_URL"
    --sparkle-feed-url "$SPARKLE_FEED_URL"
    --sparkle-public-key "$SPARKLE_PUBLIC_KEY"
    --frameworks-dir "$APP_FRAMEWORKS"
  )

  if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
    checklist_args+=(--include-llama-runtime)
  fi
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    checklist_args+=(--skip-notarize)
  fi
  if [[ "$SKIP_APPCAST" == "1" ]]; then
    checklist_args+=(--skip-appcast)
  fi

  python3 "$ROOT_DIR/script/release_checklist.py" "${checklist_args[@]}" "$@"
}

assert_beta_gate_allows_release() {
  if [[ ! -f "$BETA_GATE_RESULTS_PATH" ]]; then
    return
  fi

  local failed_rows
  failed_rows="$(awk -F '\t' 'NR > 1 && $4 == "FAILED" { print "- " $1 ": " $6 }' "$BETA_GATE_RESULTS_PATH")"
  if [[ -n "$failed_rows" ]]; then
    echo "Refusing release because beta gate results contain failures:" >&2
    echo "$failed_rows" >&2
    exit 1
  fi
}

preserve_beta_gate_artifacts() {
  if [[ ! -f "$BETA_GATE_RESULTS_PATH" ]]; then
    return
  fi

  PRESERVED_BETA_GATE_DIR="$(mktemp -d)"
  /usr/bin/ditto "$BETA_GATE_RESULTS_PATH" "$PRESERVED_BETA_GATE_DIR/beta-gate-results.tsv"

  local gate_log_dir
  for gate_log_dir in "$OUTPUT_DIR"/beta-gate-logs-*; do
    if [[ -d "$gate_log_dir" ]]; then
      /usr/bin/ditto "$gate_log_dir" "$PRESERVED_BETA_GATE_DIR/$(basename "$gate_log_dir")"
    fi
  done
}

restore_beta_gate_artifacts() {
  if [[ -z "$PRESERVED_BETA_GATE_DIR" ]]; then
    return
  fi

  mkdir -p "$OUTPUT_DIR"
  /usr/bin/ditto "$PRESERVED_BETA_GATE_DIR" "$OUTPUT_DIR"
  rm -rf "$PRESERVED_BETA_GATE_DIR"
  PRESERVED_BETA_GATE_DIR=""
}

run_release_swift() {
  if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
    "$@"
  else
    env -u AUTOCOMP_ENABLE_LLAMA_RUNTIME -u AUTOCOMP_LLAMA_CFLAGS -u AUTOCOMP_LLAMA_LIBS "$@"
  fi
}

configure_llama_runtime_request() {
  local has_cflags=0
  local has_libs=0

  [[ -n "${AUTOCOMP_LLAMA_CFLAGS:-}" ]] && has_cflags=1
  [[ -n "${AUTOCOMP_LLAMA_LIBS:-}" ]] && has_libs=1

  if [[ "$has_cflags" -ne "$has_libs" ]]; then
    echo "Set both AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS, or unset both to use pkg-config llama." >&2
    exit 1
  fi

  if [[ "$has_cflags" -eq 0 ]]; then
    export AUTOCOMP_ENABLE_LLAMA_RUNTIME=1
  fi
}

collect_llama_linker_flags() {
  if [[ -n "${AUTOCOMP_LLAMA_LIBS:-}" ]]; then
    # shellcheck disable=SC2206
    local manual_libs=($AUTOCOMP_LLAMA_LIBS)
    printf '%s\n' "${manual_libs[@]}"
    return
  fi

  local packages=()
  if pkg-config --exists ggml; then
    packages+=("ggml")
  fi
  packages+=("llama")

  local package
  for package in "${packages[@]}"; do
    # shellcheck disable=SC2207
    local package_libs=($(pkg-config --libs "$package"))
    printf '%s\n' "${package_libs[@]}"
  done
}

configure_llama_library_path() {
  local library_dirs=()
  local flag

  while IFS= read -r flag; do
    if [[ "$flag" == -L* && -n "${flag#-L}" ]]; then
      library_dirs+=("${flag#-L}")
    fi
  done < <(collect_llama_linker_flags)

  if [[ "${#library_dirs[@]}" -gt 0 ]]; then
    local value
    value="$(IFS=:; echo "${library_dirs[*]}")"
    export DYLD_LIBRARY_PATH="$value${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  fi
}

resolve_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

otool_dependencies() {
  otool -L "$1" | awk 'NR > 1 { print $1 }'
}

is_llama_runtime_dylib() {
  local path="$1"
  local name
  name="$(basename "$path")"
  [[ "$name" == libllama*.dylib || "$name" == libggml*.dylib ]]
}

bundled_dylib_for_original() {
  local original="$1"
  if [[ "${#LLAMA_ORIGINAL_DYLIBS[@]}" -eq 0 ]]; then
    return 1
  fi
  local index=0
  for candidate in "${LLAMA_ORIGINAL_DYLIBS[@]}"; do
    if [[ "$candidate" == "$original" ]]; then
      printf '%s\n' "${LLAMA_BUNDLED_DYLIBS[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

record_bundled_dylib() {
  local original="$1"
  local bundled="$2"
  if bundled_dylib_for_original "$original" >/dev/null; then
    return
  fi
  LLAMA_ORIGINAL_DYLIBS+=("$original")
  LLAMA_BUNDLED_DYLIBS+=("$bundled")
}

copy_llama_dylib_closure() {
  local source="$1"
  local resolved
  resolved="$(resolve_path "$source")"
  if [[ ! -f "$resolved" ]]; then
    echo "Required llama runtime dylib not found: $source" >&2
    exit 1
  fi

  local existing_destination=""
  if existing_destination="$(bundled_dylib_for_original "$resolved" 2>/dev/null)"; then
    record_bundled_dylib "$source" "$existing_destination"
    return
  fi

  local destination="$APP_FRAMEWORKS/$(basename "$resolved")"
  /usr/bin/ditto "$resolved" "$destination"
  chmod u+w "$destination"
  record_bundled_dylib "$source" "$destination"
  record_bundled_dylib "$resolved" "$destination"

  local dependency
  while IFS= read -r dependency; do
    if [[ "$dependency" == /* ]] && is_llama_runtime_dylib "$dependency"; then
      copy_llama_dylib_closure "$dependency"
    fi
  done < <(otool_dependencies "$resolved")
}

rewrite_llama_runtime_links() {
  if [[ "${#LLAMA_BUNDLED_DYLIBS[@]}" -eq 0 ]]; then
    echo "No llama runtime dylibs were discovered in $APP_BINARY." >&2
    exit 1
  fi

  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"

  local target
  for target in "$APP_BINARY" "${LLAMA_BUNDLED_DYLIBS[@]}"; do
    local index=0
    for original in "${LLAMA_ORIGINAL_DYLIBS[@]}"; do
      local bundled="${LLAMA_BUNDLED_DYLIBS[$index]}"
      local name
      name="$(basename "$bundled")"
      local original_name
      original_name="$(basename "$original")"
      /usr/bin/install_name_tool -change "$original" "@rpath/$name" "$target" 2>/dev/null || true
      /usr/bin/install_name_tool -change "@rpath/$original_name" "@rpath/$name" "$target" 2>/dev/null || true
      index=$((index + 1))
    done
  done

  for target in "${LLAMA_BUNDLED_DYLIBS[@]}"; do
    /usr/bin/install_name_tool -id "@rpath/$(basename "$target")" "$target"
  done
}

verify_llama_runtime_links() {
  local target
  for target in "$APP_BINARY" "${LLAMA_BUNDLED_DYLIBS[@]}"; do
    if otool -L "$target" | grep -E '(/opt/homebrew|/usr/local|Cellar).*(libllama|libggml)' >/dev/null; then
      echo "Bundled llama runtime link still points outside the app bundle: $target" >&2
      otool -L "$target" >&2
      exit 1
    fi
  done
}

bundle_llama_runtime_dylibs() {
  mkdir -p "$APP_FRAMEWORKS"

  local dependency
  while IFS= read -r dependency; do
    if [[ "$dependency" == /* ]] && is_llama_runtime_dylib "$dependency"; then
      copy_llama_dylib_closure "$dependency"
    fi
  done < <(otool_dependencies "$APP_BINARY")

  rewrite_llama_runtime_links
  verify_llama_runtime_links
}

run_dry_plan() {
  echo "Release dry run:"
  if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
    cat <<PLAN
+ script/check_llama_pkg_config.sh
+ AUTOCOMP_ENABLE_LLAMA_RUNTIME=1 swift build -c release --product "$APP_NAME"
+ copy llama/ggml dylibs into "$APP_FRAMEWORKS"
+ rewrite llama/ggml install names and rpaths to @rpath inside the app bundle
+ verify otool links for bundled llama/ggml dylibs do not point at Homebrew paths
PLAN
  else
    echo "+ swift build -c release --product \"$APP_NAME\" with optional llama runtime disabled"
  fi
  cat <<PLAN
+ stage "$APP_BUNDLE" with version "$VERSION" build "$BUILD_NUMBER"
+ fetch Sparkle "$SPARKLE_VERSION" from "$SPARKLE_ARCHIVE_URL" unless AUTOCOMP_SPARKLE_FRAMEWORK_PATH is set
+ embed Sparkle.framework in "$APP_FRAMEWORKS"
+ add SUFeedURL and SUPublicEDKey to "$INFO_PLIST"
+ codesign --force --options runtime --sign "\${AUTOCOMP_RELEASE_SIGNING_IDENTITY}" "$APP_FRAMEWORKS/Sparkle.framework"
PLAN
  if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
    echo '+ codesign --force --options runtime --sign "${AUTOCOMP_RELEASE_SIGNING_IDENTITY}" "$APP_FRAMEWORKS"/lib{llama,ggml}*.dylib'
  fi
  cat <<PLAN
+ codesign --force --deep --options runtime --sign "\${AUTOCOMP_RELEASE_SIGNING_IDENTITY}" "$APP_BUNDLE"
+ codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
+ script/release_dmg.sh --app-path "$APP_BUNDLE" --output-path "$DMG_PATH" --volume-name "$APP_NAME"
+ xcrun notarytool submit "$DMG_PATH" --keychain-profile "\${AUTOCOMP_NOTARY_PROFILE}" --wait
+ xcrun stapler staple "$DMG_PATH"
+ spctl -a -t exec -vv "$APP_BUNDLE"
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
  generate_release_checklist dry-run
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
assert_beta_gate_allows_release

if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
  configure_llama_runtime_request
  "$ROOT_DIR/script/check_llama_pkg_config.sh"
  configure_llama_library_path
fi

preserve_beta_gate_artifacts
rm -rf "$OUTPUT_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
restore_beta_gate_artifacts

run_release_swift swift build -c release --product "$APP_NAME"
BUILD_BINARY="$(run_release_swift swift build -c release --show-bin-path)/$APP_NAME"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
  bundle_llama_runtime_dylibs
fi
copy_sparkle_framework

if [[ -d "$ROOT_DIR/Resources" ]]; then
  rsync -a --delete "$ROOT_DIR/Resources/" "$APP_RESOURCES/Resources/"
fi

write_info_plist

/usr/bin/codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_FRAMEWORKS/Sparkle.framework"
if [[ "$INCLUDE_LLAMA_RUNTIME" == "1" ]]; then
  for bundled_dylib in "${LLAMA_BUNDLED_DYLIBS[@]}"; do
    /usr/bin/codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$bundled_dylib"
  done
fi
/usr/bin/codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

"$ROOT_DIR/script/release_dmg.sh" \
  --app-path "$APP_BUNDLE" \
  --output-path "$DMG_PATH" \
  --volume-name "$APP_NAME"

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl -a -t exec -vv "$APP_BUNDLE"
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

generate_release_checklist release --enforce-blockers
echo "Release artifacts written to: $OUTPUT_DIR"
