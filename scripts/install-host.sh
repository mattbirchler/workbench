#!/bin/sh
# Installs the Workbench host on a Linux machine:
#
#   curl -fsSL https://raw.githubusercontent.com/mattbirchler/workbench/main/scripts/install-host.sh | sh
#
# It puts one program, workbench-host, in ~/.local/bin, sets it running in
# the background, and tells you how to pair. Nothing is installed as root.
set -eu

BASE=${WORKBENCH_HOST_URL:-https://github.com/mattbirchler/workbench/releases/download/host-latest}
BIN=${WORKBENCH_HOST_BIN:-$HOME/.local/bin}

[ "$(uname -s)" = Linux ] || { echo "This installs the Workbench host on Linux. On a Mac, use the Workbench app." >&2; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) echo "Workbench host is built for 64-bit Intel and ARM. This machine is $(uname -m)." >&2; exit 1 ;;
esac

name=workbench-host-linux-$arch.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
  else echo "Need curl or wget to download." >&2; exit 1
  fi
}

echo "Downloading the Workbench host..."
fetch "$BASE/$name" "$tmp/$name"
if fetch "$BASE/$name.sha256" "$tmp/$name.sha256" 2>/dev/null && command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp" && sha256sum -c "$name.sha256" >/dev/null) || { echo "The download doesn't match its checksum. Not installing." >&2; exit 1; }
fi
tar -xzf "$tmp/$name" -C "$tmp"
mkdir -p "$BIN"
# Move into place in one step, so a running host isn't half replaced.
mv "$tmp/workbench-host" "$BIN/workbench-host.new"
chmod 755 "$BIN/workbench-host.new"
mv "$BIN/workbench-host.new" "$BIN/workbench-host"
echo "Installed workbench-host $("$BIN/workbench-host" version) in $BIN"

"$BIN/workbench-host" service install || true

case ":$PATH:" in
  *":$BIN:"*) run=workbench-host ;;
  *) run=$BIN/workbench-host
     echo "Note: $BIN isn't on your PATH, so use the full path below, or add it." ;;
esac

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  echo
  echo "Claude Code isn't installed here yet. Install it, then run claude once to sign in:"
  echo "  curl -fsSL https://claude.ai/install.sh | bash"
fi

cat <<NEXT

Next:
  $run add ~/path/to/a/project
      Add a project. You can also add them from the app.
  $run pair
      Print the link that pairs your Mac or iPhone.
      Add --relay if this machine isn't on Tailscale.
NEXT
