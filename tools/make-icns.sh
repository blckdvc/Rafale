#!/bin/bash
# Dessine l'icône puis en tire Resources/AppIcon.icns et Resources/MenuIcon.png.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
swift tools/make-icon.swift "$TMP"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/MenuIcon.png" Resources/MenuIcon.png
cp "$TMP/icon-1024.png" docs/icon.png
rm -rf "$TMP"
echo "OK : Resources/AppIcon.icns"
