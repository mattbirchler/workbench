#!/bin/bash
# Builds Ghostty's terminal engine (libghostty-vt) as a static library for
# the Workbench host, into build/ghostty-vt/<target>/. Uses vendor/ghostty
# and vendor/zig, fetching them if scripts/build-ghostty.sh hasn't.
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

# The versions the Mac app is built with, so both use the same engine.
GHOSTTY_COMMIT=$(sed -n 's/^GHOSTTY_COMMIT="\(.*\)"/\1/p' "$ROOT/scripts/build-ghostty.sh")
ZIG_VERSION=$(sed -n 's/^ZIG_VERSION="\(.*\)"/\1/p' "$ROOT/scripts/build-ghostty.sh")

# On a Mac scripts/build-ghostty.sh has already fetched these. Anywhere
# else (Linux, CI) fetch them here.
if [ ! -x "$ZIG" ] || [ "$("$ZIG" version)" != "$ZIG_VERSION" ]; then
  case "$(uname -s)" in Darwin) os=macos ;; *) os=linux ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
  echo "Downloading Zig $ZIG_VERSION"
  rm -rf "$ROOT/vendor/zig" && mkdir -p "$ROOT/vendor/zig"
  curl -sSfL "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-$os-$ZIG_VERSION.tar.xz" \
    | tar -xJ -C "$ROOT/vendor/zig" --strip-components 1
fi
if [ ! -d "$ROOT/vendor/ghostty" ]; then
  git clone --quiet https://github.com/ghostty-org/ghostty.git "$ROOT/vendor/ghostty"
  git -C "$ROOT/vendor/ghostty" checkout --quiet "$GHOSTTY_COMMIT"
fi

cd "$ROOT/vendor/ghostty"
for target in "${TARGETS[@]}"; do
  echo "Building libghostty-vt for $target"
  rm -rf "$OUT/$target"
  "$ZIG" build -Demit-lib-vt -Dtarget="$target" -Doptimize=ReleaseFast --prefix "$OUT/$target"
  # Only the static library, so nothing links the shared one by accident.
  find "$OUT/$target/lib" -mindepth 1 -maxdepth 1 ! -name "libghostty-vt.a" -exec rm -rf {} +
done
