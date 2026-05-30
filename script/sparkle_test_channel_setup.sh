#!/usr/bin/env bash
set -euo pipefail

# Sparkle test-channel helper.
#
# Purpose:
# - Generate a minimal local appcast for a DMG/ZIP from the current release helper.
# - Create variants to exercise common failure modes (invalid signature, missing file)
# - Print instructions to point AutoComp at the local appcast via Info.plist overrides
#
# This script is intentionally "offline" and does not modify the app bundle.
# It produces files you can host via a simple local HTTP server.

SELF_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage:
  $SELF_NAME --archive <path.dmg|path.zip> --out-dir <dir> [--channel beta]

Generates a local Sparkle appcast and failure-case variants.

Inputs:
  --archive    Path to DMG or ZIP release artifact.
  --out-dir    Output directory for appcast and any copied artifacts.
  --channel    Optional: stable|beta (default: beta)

Environment (optional):
  AUTOCOMP_APPCAST_BASE_URL
    Base URL where you will serve the output directory, e.g. http://127.0.0.1:8000
    If set, enclosure URLs will be absolute. If not set, they will be relative.

  AUTOCOMP_SPARKLE_SIGN_UPDATE
  AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE
    If provided, will sign the archive via script/release_appcast.py.

Output files:
  - appcast.xml                      : valid appcast
  - appcast_invalid_signature.xml    : same as above but with broken sparkle signature attribute
  - appcast_missing_file.xml         : points enclosure to a non-existent file
  - <copied archive>                 : copy of input archive placed in out-dir

Exit codes:
  0 success
  2 usage / missing prerequisites
EOF
}

fail() {
    echo "[FAIL] $*" >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE=""
OUT_DIR=""
CHANNEL="beta"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)
            ARCHIVE="${2:-}"; shift 2 ;;
        --out-dir)
            OUT_DIR="${2:-}"; shift 2 ;;
        --channel)
            CHANNEL="${2:-}"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown arg: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[[ -n "$ARCHIVE" ]] || fail "--archive is required"
[[ -n "$OUT_DIR" ]] || fail "--out-dir is required"
[[ -f "$ARCHIVE" ]] || fail "Archive not found: $ARCHIVE"

mkdir -p "$OUT_DIR"

ARCHIVE_BASENAME="$(basename "$ARCHIVE")"
STAGED_ARCHIVE="$OUT_DIR/$ARCHIVE_BASENAME"
cp -f "$ARCHIVE" "$STAGED_ARCHIVE"

APPCAST_XML="$OUT_DIR/appcast.xml"
APPCAST_INVALID_SIG_XML="$OUT_DIR/appcast_invalid_signature.xml"
APPCAST_MISSING_FILE_XML="$OUT_DIR/appcast_missing_file.xml"

BASE_URL="${AUTOCOMP_APPCAST_BASE_URL:-}"
ENCLOSURE_URL="$ARCHIVE_BASENAME"
if [[ -n "$BASE_URL" ]]; then
    # Trim trailing slash
    BASE_URL="${BASE_URL%/}"
    ENCLOSURE_URL="$BASE_URL/$ARCHIVE_BASENAME"
fi

SIGN_UPDATE_TOOL="${AUTOCOMP_SPARKLE_SIGN_UPDATE:-}"
APPCAST_ARGS=()
if [[ -n "$SIGN_UPDATE_TOOL" && -n "${AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    APPCAST_ARGS+=(--sign-update-tool "$SIGN_UPDATE_TOOL")
    APPCAST_ARGS+=(--private-key-file "$AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE")
else
    APPCAST_ARGS+=(--dry-run)
    echo "[WARN] Sparkle signing inputs missing; generated appcast uses dry-run signature data." >&2
fi

python3 "$SCRIPT_DIR/release_appcast.py" \
    --version "999.0.0" \
    --build "999000" \
    --archive "$STAGED_ARCHIVE" \
    --download-url "$ENCLOSURE_URL" \
    --release-notes-url "https://example.invalid/autocomp-test-channel" \
    --output "$APPCAST_XML" \
    "${APPCAST_ARGS[@]}" >/dev/null

if [[ "$CHANNEL" != "stable" ]]; then
    /usr/bin/python3 - "$APPCAST_XML" "$CHANNEL" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
channel = sys.argv[2]
text = path.read_text(encoding="utf-8")
text = re.sub(r"(<enclosure\b)", rf'\1 sparkle:channel="{channel}"', text, count=1)
path.write_text(text, encoding="utf-8")
PY
fi

/usr/bin/python3 - "$APPCAST_XML" "$APPCAST_INVALID_SIG_XML" "$APPCAST_MISSING_FILE_XML" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
invalid = re.sub(r'(sparkle:(?:edSignature|dsaSignature))="[^"]+"', r'\1="INVALID"', source)
missing = re.sub(r'url="[^"]+"', 'url="missing-file-does-not-exist.dmg"', source, count=1)
pathlib.Path(sys.argv[2]).write_text(invalid, encoding="utf-8")
pathlib.Path(sys.argv[3]).write_text(missing, encoding="utf-8")
PY

cat >&2 <<EOF
[PASS] Generated test appcast files in: $OUT_DIR

Next steps (manual):
  1) Serve the directory:
       cd '$OUT_DIR' && python3 -m http.server 8000


  2) Point AutoComp at the test appcast.
     AutoComp requires SUFeedURL and SUPublicEDKey in its Info.plist.

     - If you have a local build where you can edit Info.plist:
         SUFeedURL = http://127.0.0.1:8000/appcast.xml

     - For negative tests:
         http://127.0.0.1:8000/appcast_invalid_signature.xml
         http://127.0.0.1:8000/appcast_missing_file.xml

  3) In AutoComp menu: Check for Updates…

Expected behaviors:
  - Valid appcast.xml:
      Sparkle offers an update (if its version is higher than installed), downloads, validates signature, and installs.
  - appcast_invalid_signature.xml:
      Sparkle rejects the update with a signature validation error; app remains installed and functional.
  - appcast_missing_file.xml:
      Sparkle fails download (404); app remains installed and functional.

Rollback / downgrade check:
  - Ensure the appcast item has sparkle:shortVersionString and sparkle:version greater than the installed app.
  - Then try an appcast where those are LOWER than installed; Sparkle should not offer a downgrade.
EOF
