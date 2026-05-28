#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE_FILE="$TMP_DIR/llama_link_check.c"
BINARY_FILE="$TMP_DIR/llama_link_check"

if [[ -n "${AUTOCOMP_LLAMA_CFLAGS:-}" || -n "${AUTOCOMP_LLAMA_LIBS:-}" ]]; then
  if [[ -z "${AUTOCOMP_LLAMA_CFLAGS:-}" || -z "${AUTOCOMP_LLAMA_LIBS:-}" ]]; then
    echo "Set both AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS, or unset both to use pkg-config llama." >&2
    exit 1
  fi
  read -r -a LLAMA_CFLAGS <<<"$AUTOCOMP_LLAMA_CFLAGS"
  read -r -a LLAMA_LIBS <<<"$AUTOCOMP_LLAMA_LIBS"
  SOURCE_DESCRIPTION="explicit AUTOCOMP_LLAMA_CFLAGS/AUTOCOMP_LLAMA_LIBS"
else
  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required unless AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS are set." >&2
    exit 1
  fi

  if ! pkg-config --exists llama; then
    echo "pkg-config could not find llama. Install llama.cpp with pkg-config metadata or set AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS." >&2
    exit 1
  fi

  PKG_CONFIG_PACKAGES=()
  if pkg-config --exists ggml; then
    PKG_CONFIG_PACKAGES+=("ggml")
  fi
  PKG_CONFIG_PACKAGES+=("llama")

  LLAMA_CFLAGS=()
  LLAMA_LIBS=()
  for package in "${PKG_CONFIG_PACKAGES[@]}"; do
    read -r -a PACKAGE_CFLAGS <<<"$(pkg-config --cflags "$package")"
    read -r -a PACKAGE_LIBS <<<"$(pkg-config --libs "$package")"
    LLAMA_CFLAGS+=("${PACKAGE_CFLAGS[@]}")
    LLAMA_LIBS+=("${PACKAGE_LIBS[@]}")
  done
  SOURCE_DESCRIPTION="pkg-config ${PKG_CONFIG_PACKAGES[*]}"
fi

LIBRARY_DIRS=()
for flag in "${LLAMA_LIBS[@]}"; do
  if [[ "$flag" == -L* && -n "${flag#-L}" ]]; then
    LIBRARY_DIRS+=("${flag#-L}")
  fi
done

cat >"$SOURCE_FILE" <<'C'
#include <llama.h>

int main(void) {
    llama_backend_init();
    llama_backend_free();
    return 0;
}
C

if ! COMPILE_OUTPUT="$(cc "${LLAMA_CFLAGS[@]}" "$SOURCE_FILE" "${LLAMA_LIBS[@]}" -o "$BINARY_FILE" 2>&1)"; then
  echo "$COMPILE_OUTPUT" >&2
  echo "llama.cpp link check failed. Fix pkg-config llama/ggml metadata or set AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS explicitly." >&2
  exit 1
fi

if [[ "${#LIBRARY_DIRS[@]}" -gt 0 ]]; then
  LIBRARY_PATH_VALUE="$(IFS=:; echo "${LIBRARY_DIRS[*]}")"
  if ! RUN_OUTPUT="$(DYLD_LIBRARY_PATH="$LIBRARY_PATH_VALUE${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$BINARY_FILE" 2>&1)"; then
    echo "$RUN_OUTPUT" >&2
    echo "llama.cpp runtime check failed. Verify the linked dynamic libraries are loadable." >&2
    exit 1
  fi
else
  if ! RUN_OUTPUT="$("$BINARY_FILE" 2>&1)"; then
    echo "$RUN_OUTPUT" >&2
    echo "llama.cpp runtime check failed. Verify the linked dynamic libraries are loadable." >&2
    exit 1
  fi
fi

echo "llama.cpp link check passed using $SOURCE_DESCRIPTION"
echo "cflags: ${LLAMA_CFLAGS[*]}"
echo "libs: ${LLAMA_LIBS[*]}"
