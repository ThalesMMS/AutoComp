#!/usr/bin/env bash
set -euo pipefail

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "pkg-config is required to validate llama.cpp linking." >&2
  exit 1
fi

if ! pkg-config --exists llama; then
  echo "pkg-config could not find llama. Install llama.cpp with Homebrew before enabling local runtime builds." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE_FILE="$TMP_DIR/llama_link_check.c"
BINARY_FILE="$TMP_DIR/llama_link_check"
LLAMA_LIB_DIR="$(pkg-config --variable=libdir llama)"
HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-}"

if [[ -z "$HOMEBREW_PREFIX" ]]; then
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_PREFIX="$(brew --prefix)"
  else
    HOMEBREW_PREFIX="/opt/homebrew"
  fi
fi

read -r -a LLAMA_CFLAGS <<<"$(pkg-config --cflags llama)"
read -r -a LLAMA_LIBS <<<"$(pkg-config --libs llama)"

EXTRA_CFLAGS=()
EXTRA_LIBS=()
if [[ -f "$HOMEBREW_PREFIX/include/ggml.h" ]]; then
  EXTRA_CFLAGS+=("-I$HOMEBREW_PREFIX/include")
fi
if [[ -d "$HOMEBREW_PREFIX/lib" ]]; then
  EXTRA_LIBS+=("-L$HOMEBREW_PREFIX/lib")
fi

cat >"$SOURCE_FILE" <<'C'
#include <llama.h>

int main(void) {
    llama_backend_init();
    llama_backend_free();
    return 0;
}
C

cc "${LLAMA_CFLAGS[@]}" "${EXTRA_CFLAGS[@]}" "$SOURCE_FILE" "${LLAMA_LIBS[@]}" "${EXTRA_LIBS[@]}" -o "$BINARY_FILE"
DYLD_LIBRARY_PATH="${LLAMA_LIB_DIR}:$HOMEBREW_PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$BINARY_FILE"

echo "llama.cpp pkg-config link check passed"
echo "cflags: $(pkg-config --cflags llama)"
echo "libs: $(pkg-config --libs llama)"
