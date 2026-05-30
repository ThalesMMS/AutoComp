#!/bin/bash
# Validate a Sparkle appcast (RSS) for structural correctness and common update issues.
# - Checks for required <item> fields (enclosure + sparkle version metadata)
# - Optionally checks URL reachability for enclosures and release notes
# - Optionally compares against a current installed version to detect downgrades
#
# This is a validator only; it does not modify files.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# -------- Output helpers --------
IS_GHA=0
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  IS_GHA=1
fi

group_start() {
  local title="$1"
  if [[ "$IS_GHA" -eq 1 ]]; then
    echo "::group::${title}"
  else
    echo "==== ${title} ===="
  fi
}

group_end() {
  if [[ "$IS_GHA" -eq 1 ]]; then
    echo "::endgroup::"
  fi
}

log() { echo "[INFO] $*"; }
pass() { echo "[PASS] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[FAIL] $*"; fail_count=$((fail_count + 1)); }

fail_count=0

die() {
  fail "$*"
  exit 2
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
}

usage() {
  cat <<'EOF'
Validate a Sparkle appcast (RSS) for common production issues.

USAGE:
  script/release_validate_appcast.sh --appcast <path-or-url> [options]

REQUIRED:
  --appcast <path-or-url>         Local file path or https URL to an appcast XML.
                                  Aliases: --path, --file, --url.

OPTIONS:
  --current-short-version <ver>   Current CFBundleShortVersionString (e.g. 1.2.3).
  --current-bundle-version <ver>  Current CFBundleVersion/build number (e.g. 123).
  --check-urls                    Perform HEAD/GET checks for enclosure and releaseNotesLink URLs.
  --allow-http                    Allow non-https URLs (default: warn).
  --max-items N                   Validate at most N <item> entries (default: 20).
  --strict                        Treat warnings as failures.
  -h, --help                      Show help.

EXIT CODES:
  0  success
  2  invalid usage / missing prereqs
  3  validation failed

NOTES:
  - This script intentionally does not print any secrets.
  - It performs best-effort XML parsing using xmllint when available.

EXAMPLES:
  script/release_validate_appcast.sh --appcast ./dist/appcast.xml
  script/release_validate_appcast.sh --appcast https://example.com/appcast.xml --check-urls
  script/release_validate_appcast.sh --appcast ./appcast.xml --current-short-version 1.4.0 --current-bundle-version 140
EOF
}

# -------- Args --------
APPCAST=""
CURRENT_SHORT_VERSION=""
CURRENT_BUNDLE_VERSION=""
CHECK_URLS=0
ALLOW_HTTP=0
MAX_ITEMS=20
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appcast|--path|--file|--url)
      APPCAST="$2"; shift 2 ;;
    --current-short-version)
      CURRENT_SHORT_VERSION="$2"; shift 2 ;;
    --current-bundle-version)
      CURRENT_BUNDLE_VERSION="$2"; shift 2 ;;
    --check-urls)
      CHECK_URLS=1; shift ;;
    --allow-http)
      ALLOW_HTTP=1; shift ;;
    --max-items)
      MAX_ITEMS="$2"; shift 2 ;;
    --strict)
      STRICT=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$APPCAST" ]]; then
  usage >&2
  exit 2
fi

# -------- prereqs --------
require_command /usr/bin/python3
require_command grep
require_command sed
require_command awk

HAVE_XMLLINT=0
if command -v xmllint >/dev/null 2>&1; then
  HAVE_XMLLINT=1
fi

HAVE_CURL=0
if command -v curl >/dev/null 2>&1; then
  HAVE_CURL=1
fi

if [[ "$CHECK_URLS" -eq 1 && "$HAVE_CURL" -ne 1 ]]; then
  echo "curl is required for --check-urls" >&2
  exit 2
fi

# -------- fetch/read appcast --------
TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMPDIR%/}/autocomp_appcast_validate.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

APPCAST_FILE="${WORK_DIR}/appcast.xml"

is_url() {
  [[ "$1" =~ ^https?:// ]]
}

fetch_appcast() {
  local src="$1"
  if is_url "$src"; then
    if [[ "$HAVE_CURL" -ne 1 ]]; then
      die "curl is required to fetch URL appcasts"
    fi
    curl -fsSL "$src" -o "$APPCAST_FILE" || die "Failed to fetch appcast from URL"
  else
    [[ -f "$src" ]] || die "Appcast file not found: $src"
    cp "$src" "$APPCAST_FILE"
  fi
}

fetch_appcast "$APPCAST"

# Basic sanity: file is non-empty and looks like XML
if [[ ! -s "$APPCAST_FILE" ]]; then
  echo "Appcast content is empty" >&2
  exit 3
fi

# -------- xml parse helpers (best effort) --------
xml_nodes() {
  # $1 xpath
  local xpath="$1"
  if [[ "$HAVE_XMLLINT" -eq 1 ]]; then
    xmllint --nocdata --xpath "$xpath" "$APPCAST_FILE" 2>/dev/null || true
  else
    # fallback: no-op (caller should handle empty)
    true
  fi
}

# Extract <item> blocks using a conservative approach when xmllint is missing.
# This is not a full XML parser but is sufficient for well-formed Sparkle appcasts.
extract_items_fallback() {
  awk '
    BEGIN { initem=0; buf="" }
    /<item[ >]/ { initem=1 }
    {
      if (initem==1) { buf = buf $0 "\n" }
    }
    /<\/item>/ {
      if (initem==1) {
        print "---ITEM---";
        print buf;
        buf="";
        initem=0;
      }
    }
  ' "$APPCAST_FILE"
}

# Version compare via Python to properly handle dotted versions.
# Returns 0 if $1 >= $2, 1 otherwise.
py_version_gte_safe() {
  local a="$1"
  local b="$2"

  # Prefer packaging when available; fall back to distutils-style loose versions.
  /usr/bin/python3 - "$a" "$b" <<'PY'
import sys

a, b = sys.argv[1], sys.argv[2]

try:
    from packaging.version import Version
    ok = Version(a) >= Version(b)
except Exception:
    try:
        from distutils.version import LooseVersion as V
    except Exception:
        from setuptools._distutils.version import LooseVersion as V
    ok = V(a) >= V(b)

print("1" if ok else "0")
PY
}

url_check() {
  local url="$1"
  local label="$2"

  if [[ "$ALLOW_HTTP" -ne 1 && "$url" =~ ^http:// ]]; then
    warn "${label}: non-https URL: $url"
    return 0
  fi

  # HEAD first; if not allowed, fall back to GET range.
  if curl -fsSI --max-time 15 "$url" >/dev/null 2>&1; then
    pass "${label}: reachable"
    return 0
  fi

  if curl -fsS --max-time 20 -r 0-0 "$url" >/dev/null 2>&1; then
    pass "${label}: reachable (GET fallback)"
    return 0
  fi

  fail "${label}: unreachable: $url"
  return 1
}

STRICT_WARNINGS=0
VALIDATION_FAILURES=0

record_warn() {
  warn "$*"
  if [[ "$STRICT" -eq 1 ]]; then
    STRICT_WARNINGS=$((STRICT_WARNINGS+1))
  fi
}

record_fail() {
  fail "$*"
  VALIDATION_FAILURES=$((VALIDATION_FAILURES+1))
}

# -------- Validation --------

group_start "Appcast root structure"
if [[ "$HAVE_XMLLINT" -eq 1 ]]; then
  if xmllint --noout "$APPCAST_FILE" >/dev/null 2>&1; then
    pass "XML well-formed"
  else
    record_fail "XML is not well-formed"
  fi

  local_rss="$(xml_nodes 'string(/rss/@version)')"
  if [[ -n "$local_rss" ]]; then
    pass "rss@version present: $local_rss"
  else
    record_warn "Missing rss@version (common but recommended)"
  fi
else
  record_warn "xmllint not found; using best-effort parsing"
fi

group_end

# Count items
ITEM_COUNT=0
if [[ "$HAVE_XMLLINT" -eq 1 ]]; then
  ITEM_COUNT="$(xml_nodes 'count(/rss/channel/item)')"
  ITEM_COUNT="${ITEM_COUNT%.*}"
else
  ITEM_COUNT="$(extract_items_fallback | grep -c '^---ITEM---$' || true)"
fi

if [[ -z "$ITEM_COUNT" || "$ITEM_COUNT" -eq 0 ]]; then
  record_fail "No <item> entries found in appcast"
  ITEM_COUNT=0
fi

if [[ "$ITEM_COUNT" -gt 0 ]]; then
  pass "Found ${ITEM_COUNT} item(s)"
fi

# Validate up to MAX_ITEMS
TO_CHECK="$ITEM_COUNT"
if [[ "$TO_CHECK" -gt "$MAX_ITEMS" ]]; then
  TO_CHECK="$MAX_ITEMS"
  record_warn "More than ${MAX_ITEMS} items; validating first ${MAX_ITEMS}"
fi

# Collect items as standalone XML snippets for parsing.
ITEM_FILES=()
if [[ "$TO_CHECK" -gt 0 ]]; then
  if [[ "$HAVE_XMLLINT" -eq 1 ]]; then
    i=1
    while [[ "$i" -le "$TO_CHECK" ]]; do
      out_file="${WORK_DIR}/item_${i}.xml"
      # Wrap item in a minimal root with namespaces to make xpath work.
      {
        echo '<root xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
        xml_nodes "/rss/channel/item[${i}]"
        echo '</root>'
      } >"$out_file"

      # xmllint --xpath can drop xmlns declarations on extracted fragments.
      # Ensure the Sparkle namespace is present on the <enclosure> element(s)
      # so that @sparkle:* attribute extraction works reliably.
      if grep -q '<enclosure' "$out_file"; then
        sed -i '' -E 's/<enclosure /<enclosure xmlns:sparkle="http:\/\/www.andymatuschak.org\/xml-namespaces\/sparkle" /' "$out_file" || true
      fi
      ITEM_FILES+=("$out_file")
      i=$((i+1))
    done
  else
    i=0
    cur=""
    while IFS= read -r line; do
      if [[ "$line" == "---ITEM---" ]]; then
        if [[ -n "$cur" ]]; then
          i=$((i+1))
          if [[ "$i" -le "$TO_CHECK" ]]; then
            out_file="${WORK_DIR}/item_${i}.xml"
            {
              echo '<root xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
              echo "$cur"
              echo '</root>'
            } >"$out_file"
            ITEM_FILES+=("$out_file")
          fi
          cur=""
        fi
      else
        cur+="$line"$'\n'
      fi
    done < <(extract_items_fallback)

    if [[ -n "$cur" ]]; then
      i=$((i+1))
      if [[ "$i" -le "$TO_CHECK" ]]; then
        out_file="${WORK_DIR}/item_${i}.xml"
        {
          echo '<root xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
          echo "$cur"
          echo '</root>'
        } >"$out_file"
        ITEM_FILES+=("$out_file")
      fi
    fi
  fi
fi

# Validate each item
idx=0
for item_file in "${ITEM_FILES[@]}"; do
  idx=$((idx+1))
  group_start "Item #${idx}"

  # Use xmllint if present; otherwise rough grep/sed extraction.
  item_title=""
  enclosure_url=""
  enclosure_len=""
  enclosure_type=""
  sparkle_short=""
  sparkle_version=""
  signature=""
  relnotes=""

  if [[ "$HAVE_XMLLINT" -eq 1 ]]; then
    item_title="$(xmllint --xpath 'string(/root/item/title)' "$item_file" 2>/dev/null || true)"
    enclosure_url="$(xmllint --xpath 'string(/root/item/enclosure/@url)' "$item_file" 2>/dev/null || true)"
    enclosure_len="$(xmllint --xpath 'string(/root/item/enclosure/@length)' "$item_file" 2>/dev/null || true)"
    enclosure_type="$(xmllint --xpath 'string(/root/item/enclosure/@type)' "$item_file" 2>/dev/null || true)"

    # Namespace quirks: when fragments are extracted, the "sparkle" prefix may not be bound.
    # Prefer local-name() based selection for robustness.
    sparkle_short="$(xmllint --xpath 'string(/root/item/enclosure/@*[local-name()="shortVersionString"])' "$item_file" 2>/dev/null || true)"
    sparkle_version="$(xmllint --xpath 'string(/root/item/enclosure/@*[local-name()="version"])' "$item_file" 2>/dev/null || true)"
    signature="$(xmllint --xpath 'string(/root/item/enclosure/@*[local-name()="edSignature" or local-name()="dsaSignature"])' "$item_file" 2>/dev/null || true)"
    relnotes="$(xmllint --xpath 'string(/root/item/*[local-name()="releaseNotesLink"])' "$item_file" 2>/dev/null || true)"
  else
    # crude fallback
    item_title="$(grep -E '<title>' "$item_file" | head -n1 | sed -E 's/.*<title>([^<]+)<\/title>.*/\1/' || true)"
    enclosure_url="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*url="([^"]+)".*/\1/' || true)"
    enclosure_len="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*length="([^"]+)".*/\1/' || true)"
    enclosure_type="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*type="([^"]+)".*/\1/' || true)"
    sparkle_short="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*shortVersionString="([^"]+)".*/\1/' || true)"
    sparkle_version="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*sparkle:version="([^"]+)".*/\1/' || true)"
    signature="$(grep -E '<enclosure ' "$item_file" | head -n1 | sed -E 's/.*(edSignature|dsaSignature)="([^"]+)".*/\2/' || true)"
    relnotes="$(grep -E 'releaseNotesLink' "$item_file" | head -n1 | sed -E 's/.*>([^<]+)<.*/\1/' || true)"
  fi

  if [[ -n "$item_title" ]]; then
    log "title: $item_title"
  fi

  if [[ -z "$enclosure_url" ]]; then
    record_fail "Missing enclosure url"
  else
    pass "enclosure url present"
  fi

  if [[ -z "$enclosure_len" ]]; then
    record_warn "Missing enclosure length"
  elif [[ ! "$enclosure_len" =~ ^[0-9]+$ ]]; then
    record_fail "Enclosure length is not an integer: $enclosure_len"
  else
    pass "enclosure length looks valid"
  fi

  if [[ -z "$enclosure_type" ]]; then
    record_warn "Missing enclosure type (MIME)"
  else
    pass "enclosure type present"
  fi

  # Sparkle supports providing version metadata either:
  # - as attributes on <enclosure> (e.g. sparkle:version, sparkle:shortVersionString), or
  # - as child elements inside <item> (e.g. <sparkle:version>123</sparkle:version>).
  # Accept both forms.

  # If enclosure attributes are missing, try item-level elements.
  if [[ -z "$sparkle_short" ]]; then
    sparkle_short="$(grep -Eo '<sparkle:shortVersionString>[^<]+' "$item_file" | head -n1 | sed -E 's#<sparkle:shortVersionString>##' || true)"
  fi
  if [[ -z "$sparkle_version" ]]; then
    sparkle_version="$(grep -Eo '<sparkle:version>[^<]+' "$item_file" | head -n1 | sed -E 's#<sparkle:version>##' || true)"
  fi

  if [[ -z "$sparkle_version" || -z "$sparkle_short" ]]; then
    record_fail "Missing Sparkle version metadata: require both sparkle:version and sparkle:shortVersionString (either enclosure attributes or item child elements)"
  else
    pass "sparkle:shortVersionString present (${sparkle_short})"
    pass "sparkle:version present (${sparkle_version})"
  fi

  if [[ -z "$signature" ]]; then
    record_warn "Missing sparkle signature attribute (sparkle:edSignature or sparkle:dsaSignature)"
  else
    pass "signature attribute present"
  fi

  if [[ -n "$relnotes" ]]; then
    pass "releaseNotesLink present"
  else
    record_warn "releaseNotesLink missing"
  fi

  if [[ "$CHECK_URLS" -eq 1 ]]; then
    if [[ -n "$enclosure_url" ]]; then
      if ! url_check "$enclosure_url" "enclosure"; then
        VALIDATION_FAILURES=$((VALIDATION_FAILURES+1))
      fi
    fi
    if [[ -n "$relnotes" ]]; then
      if ! url_check "$relnotes" "releaseNotesLink"; then
        VALIDATION_FAILURES=$((VALIDATION_FAILURES+1))
      fi
    fi
  fi

  # Version ordering check vs current
  if [[ -n "$CURRENT_BUNDLE_VERSION" && -n "$sparkle_version" ]]; then
    if [[ "$sparkle_version" =~ ^[0-9]+$ && "$CURRENT_BUNDLE_VERSION" =~ ^[0-9]+$ ]]; then
      if (( sparkle_version < CURRENT_BUNDLE_VERSION )); then
        record_fail "sparkle:version ($sparkle_version) is lower than current bundle version ($CURRENT_BUNDLE_VERSION) => downgrade/rollback"
      else
        pass "sparkle:version is >= current bundle version"
      fi
    else
      record_warn "Cannot compare non-integer bundle versions (sparkle:version=$sparkle_version, current=$CURRENT_BUNDLE_VERSION)"
    fi
  fi

  if [[ -n "$CURRENT_SHORT_VERSION" && -n "$sparkle_short" ]]; then
    cmp="$(py_version_gte_safe "$sparkle_short" "$CURRENT_SHORT_VERSION" || echo "0")"
    if [[ "$cmp" != "1" ]]; then
      record_fail "sparkle:shortVersionString ($sparkle_short) is lower than current short version ($CURRENT_SHORT_VERSION) => downgrade/rollback"
    else
      pass "sparkle:shortVersionString is >= current short version"
    fi
  fi

  group_end

done

# Final status
if [[ "$STRICT_WARNINGS" -gt 0 ]]; then
  VALIDATION_FAILURES=$((VALIDATION_FAILURES+STRICT_WARNINGS))
fi

if [[ "$VALIDATION_FAILURES" -gt 0 ]]; then
  echo "Validation completed with ${VALIDATION_FAILURES} issue(s)." >&2
  exit 3
fi

echo "Validation OK" >&2
exit 0
