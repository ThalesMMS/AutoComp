#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERY_ONLY=0

usage() {
  cat >&2 <<'USAGE'
usage: build_without_llama.sh [--discovery-only]

Builds the supported default matrix leg with the optional local llama runtime
forced off, even when the parent shell has local-runtime variables set.

Environment:
  AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE   Internal discovery test fixture.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --discovery-only)
      DISCOVERY_ONLY=1
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

cd "$ROOT_DIR"

report() {
  printf 'build_without_llama: %s\n' "$*"
}

fail() {
  report "$*"
  exit 1
}

run_without_llama_env() (
  unset AUTOCOMP_ENABLE_LLAMA_RUNTIME
  unset AUTOCOMP_LLAMA_CFLAGS
  unset AUTOCOMP_LLAMA_LIBS
  "$@"
)

run_step() {
  local label="$1"
  shift

  report "running $label"
  set +e
  "$@"
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    fail "$label failed with exit status $status"
  fi
}

load_package_dump() {
  if [[ -n "${AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE:-}" ]]; then
    cat "$AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE"
    return
  fi

  run_without_llama_env swift package dump-package
}

discover_targets() {
  local package_json
  if ! package_json="$(load_package_dump 2>&1)"; then
    printf '%s\n' "$package_json" >&2
    fail "Package.swift target discovery failed"
  fi

  if ! TARGETS="$(python3 -c '
import json
import sys

raw = sys.stdin.read()
start = raw.find("{")
if start == -1:
    raise ValueError("package dump did not contain JSON")
data = json.loads(raw[start:])
print("\n".join(sorted(target["name"] for target in data.get("targets", []))))
' <<<"$package_json")"; then
    printf '%s\n' "$package_json" >&2
    fail "Package.swift target discovery did not produce valid JSON"
  fi
}

contains_target() {
  local target="$1"
  grep -Fxq "$target" <<<"$TARGETS"
}

require_target() {
  local target="$1"
  if ! contains_target "$target"; then
    report "Discovered targets:"
    printf '%s\n' "$TARGETS"
    fail "Missing required no-llama target: $target"
  fi
}

reject_target() {
  local target="$1"
  if contains_target "$target"; then
    report "Discovered targets:"
    printf '%s\n' "$TARGETS"
    fail "No-llama build unexpectedly includes optional runtime target: $target"
  fi
}

discover_targets

for target in AutoCompApp AutoCompCore AutoCompAppTests AutoCompCoreTests; do
  require_target "$target"
done

for target in AutoCompLlamaRuntime CLlamaBridge AutoCompLlamaLoadHarness AutoCompLlamaRuntimeTests; do
  reject_target "$target"
done

report "no-llama manifest excludes optional local runtime targets"

if [[ "$DISCOVERY_ONLY" == "1" ]]; then
  report "discovery-only complete"
  exit 0
fi

run_step "swift build --product AutoComp" run_without_llama_env swift build --product AutoComp
run_step "unavailable local-runtime fallback test" \
  run_without_llama_env swift test --filter CompletionBackendConfigurationServiceTests/testInternalLocalSettingsLoadFromDefaults

report "no-llama build matrix passed with unavailable local-runtime fallback"
