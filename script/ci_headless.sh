#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXIT_BUILD_FAILURE=10
EXIT_TEST_FAILURE=11
EXIT_RELEASE_DRY_RUN_FAILURE=12
EXIT_MISSING_TARGET=20
EXIT_ENVIRONMENT_SKIP=30

DISCOVERY_ONLY=0

usage() {
  cat >&2 <<'USAGE'
usage: ci_headless.sh [--discovery-only]

Runs deterministic build/test coverage that does not launch AutoComp or depend on
Accessibility, AppleEvents, TextEdit, System Events, or real host apps.

Exit codes:
  10  build or package discovery failure
  11  test failure
  12  release dry-run failure
  20  missing expected test target
  30  required optional environment is unavailable

Environment:
  AUTOCOMP_CI_EXPECT_TEST_TARGETS   Space/comma-separated target override.
  AUTOCOMP_CI_REQUIRE_LLAMA_TESTS   Set to 1 to require AutoCompLlamaRuntimeTests.
  AUTOCOMP_CI_RUN_LLAMA_MATRIX      Set to 1 to run build_with_llama.sh.
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

cd "$ROOT_DIR" || exit "$EXIT_BUILD_FAILURE"

report() {
  printf 'ci_headless: %s\n' "$*"
}

fail() {
  local code="$1"
  shift
  report "$*"
  exit "$code"
}

run_step() {
  local label="$1"
  local failure_code="$2"
  shift 2

  report "running $label"
  "$@"
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$failure_code" "$label failed with exit status $status"
  fi
}

run_without_llama_env() (
  unset AUTOCOMP_ENABLE_LLAMA_RUNTIME
  unset AUTOCOMP_LLAMA_CFLAGS
  unset AUTOCOMP_LLAMA_LIBS
  "$@"
)

split_expected_targets() {
  local raw="${AUTOCOMP_CI_EXPECT_TEST_TARGETS:-AutoCompCoreTests AutoCompAppTests}"
  raw="${raw//,/ }"
  # shellcheck disable=SC2206
  EXPECTED_TARGETS=($raw)
}

load_package_dump() {
  if [[ -n "${AUTOCOMP_CI_PACKAGE_DUMP_FILE:-}" ]]; then
    cat "$AUTOCOMP_CI_PACKAGE_DUMP_FILE"
    return
  fi

  swift package dump-package
}

discover_test_targets() {
  local package_json
  if ! package_json="$(load_package_dump 2>&1)"; then
    printf '%s\n' "$package_json" >&2
    fail "$EXIT_BUILD_FAILURE" "Package.swift target discovery failed"
  fi

  if ! TEST_TARGETS="$(python3 -c '
import json
import sys

raw = sys.stdin.read()
start = raw.find("{")
if start == -1:
    raise ValueError("package dump did not contain JSON")
data = json.loads(raw[start:])
targets = sorted(
    target["name"]
    for target in data.get("targets", [])
    if target.get("type") == "test"
)
print("\n".join(targets))
' <<<"$package_json")"; then
    printf '%s\n' "$package_json" >&2
    fail "$EXIT_BUILD_FAILURE" "Package.swift target discovery did not produce valid JSON"
  fi
}

contains_target() {
  local target="$1"
  grep -Fxq "$target" <<<"$TEST_TARGETS"
}

verify_test_directories() {
  local missing=()
  for directory in Tests/AutoCompCoreTests Tests/AutoCompAppTests Tests/AutoCompLlamaRuntimeTests; do
    if [[ ! -d "$directory" ]]; then
      missing+=("$directory")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "$EXIT_MISSING_TARGET" "Missing test source directories: ${missing[*]}"
  fi
}

verify_expected_targets() {
  split_expected_targets

  local missing=()
  for target in "${EXPECTED_TARGETS[@]}"; do
    if [[ -n "$target" ]] && ! contains_target "$target"; then
      missing+=("$target")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    report "Discovered test targets:"
    printf '%s\n' "$TEST_TARGETS"
    fail "$EXIT_MISSING_TARGET" "Missing required test target(s): ${missing[*]}"
  fi

  if contains_target "AutoCompLlamaRuntimeTests"; then
    report "optional llama runtime tests: discovered"
  elif [[ "${AUTOCOMP_CI_REQUIRE_LLAMA_TESTS:-0}" == "1" ]]; then
    fail "$EXIT_ENVIRONMENT_SKIP" "AutoCompLlamaRuntimeTests require a local-runtime build environment"
  else
    report "environment skip: AutoCompLlamaRuntimeTests not enabled in this manifest"
  fi

  report "discovered test targets:"
  printf '%s\n' "$TEST_TARGETS"
}

verify_test_directories
discover_test_targets
verify_expected_targets

if [[ "$DISCOVERY_ONLY" == "1" ]]; then
  report "discovery-only complete"
  exit 0
fi

run_step "no-llama build matrix" "$EXIT_BUILD_FAILURE" "$ROOT_DIR/script/build_without_llama.sh"
if [[ "${AUTOCOMP_CI_RUN_LLAMA_MATRIX:-0}" == "1" ]]; then
  run_step "llama build matrix" "$EXIT_BUILD_FAILURE" "$ROOT_DIR/script/build_with_llama.sh"
else
  report "environment skip: llama build matrix not requested"
fi
run_step "tests" "$EXIT_TEST_FAILURE" run_without_llama_env swift test
run_step "release dry-run" "$EXIT_RELEASE_DRY_RUN_FAILURE" \
  run_without_llama_env "$ROOT_DIR/script/release_build.sh" \
    --dry-run \
    --version 0.0.0 \
    --build 0 \
    --download-url https://example.invalid/AutoComp.dmg \
    --release-notes-url https://example.invalid/releases/v0.0.0

report "headless CI checks passed"
