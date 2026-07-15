#!/bin/bash
# Build PR Watch, assemble a .app bundle, ad-hoc codesign, and launch it.
# CLT-only machine: SwiftPM + hand-assembled bundle (no Xcode / xcodebuild).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="PR Watch.app"
BIN=".build/${CONFIG}/PRWatch"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

echo "==> stopping PR Watch"
pkill -x PRWatch 2>/dev/null || true

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/PRWatch"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PR Watch</string>
  <key>CFBundleDisplayName</key><string>PR Watch</string>
  <key>CFBundleIdentifier</key><string>com.bszaf.prwatch</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PRWatch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>PR Watch</string>
</dict></plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "${APP}"

# Skip launching in CI / when NO_OPEN is set (headless build & package).
if [ -n "${CI:-}" ] || [ -n "${NO_OPEN:-}" ]; then
  echo "Done (not launching — CI/NO_OPEN set): ${APP}"
else
  echo "==> launching"
  open "${APP}"
  echo "Done: ${APP}"
fi
