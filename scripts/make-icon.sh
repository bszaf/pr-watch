#!/bin/bash
# Render the app icon PNG and build Resources/AppIcon.icns (committed; build.sh just copies it).
set -euo pipefail
cd "$(dirname "$0")/.."

PNG="$(mktemp -d)/AppIcon-1024.png"
swift scripts/make-icon.swift "$PNG"

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
  px="${spec%%:*}"; name="${spec##*:}"
  sips -z "$px" "$px" "$PNG" --out "$SET/icon_${name}.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
