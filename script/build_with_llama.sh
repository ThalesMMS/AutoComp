#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERY_ONLY=0
MODEL_PATH="${AUTOCOMP_LOCAL_MODEL_PATH:-}"

usage() {
  cat >&2 <<'USAGE'
usage: build_with_llama.sh [--discovery-only] [--model-path PATH]

Builds the supported local-runtime matrix leg. The script validates llama.cpp
linkage before compiling runtime targets. It uses explicit
AUTOCOMP_LLAMA_CFLAGS/AUTOCOMP_LLAMA_LIBS when both are set; otherwise it opts
into the pkg-config path with AUTOCOMP_ENABLE_LLAMA_RUNTIME=1.

Environment:
  AUTOCOMP_LOCAL_MODEL_PATH                 Optional GGUF load-smoke path.
  AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE   Internal discovery test fixture.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --discovery-only)
      DISCOVERY_ONLY=1
      shift
      ;;
    --model-path)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      MODEL_PATH="$2"
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

cd "$ROOT_DIR"

report() {
  printf 'build_with_llama: %s\n' "$*"
}

fail() {
  report "$*"
  exit 1
}

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

configure_runtime_request() {
  local has_cflags=0
  local has_libs=0

  [[ -n "${AUTOCOMP_LLAMA_CFLAGS:-}" ]] && has_cflags=1
  [[ -n "${AUTOCOMP_LLAMA_LIBS:-}" ]] && has_libs=1

  if [[ "$has_cflags" -ne "$has_libs" ]]; then
    fail "Set both AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS, or unset both to use pkg-config llama."
  fi

  if [[ "$has_cflags" -eq 0 ]]; then
    export AUTOCOMP_ENABLE_LLAMA_RUNTIME=1
  fi
}

collect_linker_flags() {
  if [[ -n "${AUTOCOMP_LLAMA_LIBS:-}" ]]; then
    read -r -a manual_libs <<<"$AUTOCOMP_LLAMA_LIBS"
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
    read -r -a package_libs <<<"$(pkg-config --libs "$package")"
    printf '%s\n' "${package_libs[@]}"
  done
}

configure_runtime_library_path() {
  local library_dirs=()
  local flag

  while IFS= read -r flag; do
    if [[ "$flag" == -L* && -n "${flag#-L}" ]]; then
      library_dirs+=("${flag#-L}")
    fi
  done < <(collect_linker_flags)

  if [[ "${#library_dirs[@]}" -gt 0 ]]; then
    local value
    value="$(IFS=:; echo "${library_dirs[*]}")"
    export DYLD_LIBRARY_PATH="$value${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  fi
}

load_package_dump() {
  if [[ -n "${AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE:-}" ]]; then
    cat "$AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE"
    return
  fi

  swift package dump-package
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
    fail "Missing required llama-runtime target: $target"
  fi
}

if [[ -z "${AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE:-}" || "$DISCOVERY_ONLY" != "1" ]]; then
  configure_runtime_request
  run_step "llama.cpp link check" "$ROOT_DIR/script/check_llama_pkg_config.sh"
  configure_runtime_library_path
fi

discover_targets

for target in AutoCompApp AutoCompLlamaRuntime CLlamaBridge AutoCompLlamaLoadHarness AutoCompLlamaRuntimeTests; do
  require_target "$target"
done

report "llama manifest includes optional runtime targets"

if [[ "$DISCOVERY_ONLY" == "1" ]]; then
  report "discovery-only complete"
  exit 0
fi

run_step "swift build --target CLlamaBridge" swift build --target CLlamaBridge
run_step "swift build --target AutoCompLlamaRuntime" swift build --target AutoCompLlamaRuntime
run_step "swift build --product AutoCompLlamaLoadHarness" swift build --product AutoCompLlamaLoadHarness
run_step "swift build --product AutoComp" swift build --product AutoComp
run_step "AutoCompLlamaRuntimeTests" swift test --filter LlamaCppRuntimeBackendTests
run_step "runtime status harness" swift run AutoCompLlamaLoadHarness --status

if [[ -z "$MODEL_PATH" ]]; then
  report "no-model: AUTOCOMP_LOCAL_MODEL_PATH was not set; skipping GGUF load smoke"
elif [[ ! -f "$MODEL_PATH" ]]; then
  report "no-model: GGUF model does not exist at $MODEL_PATH; skipping GGUF load smoke"
else
  run_step "GGUF vocabulary load smoke" swift run AutoCompLlamaLoadHarness --vocab-only "$MODEL_PATH"
fi

report "llama build matrix passed"
