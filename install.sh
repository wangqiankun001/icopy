#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

if [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

pkill -x icopy >/dev/null 2>&1 || true
rm -rf "$DEST/icopy.app"
ditto build/icopy.app "$DEST/icopy.app"
echo "Installed to $DEST/icopy.app"
open "$DEST/icopy.app"
echo "icopy is running. Press ⌘⇧V to open your clipboard history."
