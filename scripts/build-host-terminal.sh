#!/bin/bash
# Builds Ghostty's terminal engine (libghostty-vt) as a static library for
# the Workbench host, into build/ghostty-vt/<target>/. Needs vendor/ghostty
# and vendor/zig, which scripts/build-ghostty.sh sets up.
#
# Zig cross-compiles, so every target builds on a Mac. With no arguments it
# builds the three the host ships for.
#
# The library needs nothing but libc, so it links into a fully static Linux
# binary. Don't pass -Dsimd=false to slim it down: without libc it carries
# its own do-nothing calloc and free, which on Linux replace the real ones
# for the whole program.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="$ROOT/vendor/zig/zig"
OUT="$ROOT/build/ghostty-vt"
TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(aarch64-macos aarch64-linux-musl x86_64-linux-musl)
fi

if [ ! -x "$ZIG" ] || [ ! -d "$ROOT/vendor/ghostty" ]; then
  echo "Run scripts/build-ghostty.sh first: it fetches Zig and Ghostty." >&2
  exit 1
fi

cd "$ROOT/vendor/ghostty"
for target in "${TARGETS[@]}"; do
  echo "Building libghostty-vt for $target"
  rm -rf "$OUT/$target"
  "$ZIG" build -Demit-lib-vt -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$OUT/$target"
  # Only the static library, so nothing links the shared one by accident.
  find "$OUT/$target/lib" -mindepth 1 -maxdepth 1 ! -name "libghostty-vt.a" -exec rm -rf {} +
done
