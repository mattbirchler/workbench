#!/bin/bash
# Builds workbench-host for Linux as one file with nothing to install beside
# it, for 64-bit ARM and Intel, into build/host-dist/.
#
# Run on Linux (or in a Linux VM or container) with Swift and its static
# Linux SDK installed:
#   swift sdk install <the static-linux bundle for your Swift version>
# and after scripts/build-host-terminal.sh has built the terminal library
# (that part cross-compiles, so it can run on a Mac first).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/build/host-dist
mkdir -p "$OUT"
VERSION=$(sed -n 's/.*static let version = "\(.*\)"/\1/p' host/Sources/HostKit/Host.swift)

for arch in aarch64 x86_64; do
  lib=$ROOT/build/ghostty-vt/$arch-linux-musl
  [ -f "$lib/lib/libghostty-vt.a" ] || { echo "Missing $lib. Run scripts/build-host-terminal.sh first." >&2; exit 1; }
  # -s leaves out the symbols, which are two thirds of the file.
  (cd host && WORKBENCH_GHOSTTY_VT=$lib swift build -c release --product workbench-host \
      --swift-sdk $arch-swift-linux-musl --scratch-path .build-$arch -Xlinker -s)
  name=workbench-host-linux-$arch
  cp host/.build-$arch/release/workbench-host "$OUT/workbench-host"
  tar -C "$OUT" -czf "$OUT/$name.tar.gz" workbench-host
  rm "$OUT/workbench-host"
  (cd "$OUT" && sha256sum $name.tar.gz > $name.tar.gz.sha256)
  echo "Built $OUT/$name.tar.gz"
done
echo "workbench-host $VERSION"
