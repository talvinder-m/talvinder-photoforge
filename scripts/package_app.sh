#!/bin/bash
# Builds PhotoForge.app as a universal (Apple Silicon + Intel) binary, ad-hoc signed,
# and zips it into dist/. Usage: scripts/package_app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${GITHUB_RUN_NUMBER:-0}}"
VERSION="1.0.${VERSION}"
APP="dist/PhotoForge.app"

for ARCH in arm64 x86_64; do
  echo "== Building ${ARCH} (release)"
  swift build -c release --triple "${ARCH}-apple-macosx14.0" --product PhotoForgeApp
done

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/PhotoForge" \
  ".build/arm64-apple-macosx/release/PhotoForgeApp" \
  ".build/x86_64-apple-macosx/release/PhotoForgeApp"
lipo -info "$APP/Contents/MacOS/PhotoForge"

# VLC playback engine, when it was built in.
VLCFW=$(find .build -path "*release*" -name "VLCKit.framework" -maxdepth 4 | head -1)
if [ -n "$VLCFW" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$VLCFW" "$APP/Contents/Frameworks/"
  echo "Bundled VLCKit from $VLCFW"
  lipo -info "$APP/Contents/Frameworks/VLCKit.framework/VLCKit" || true
fi

sed "s/__VERSION__/${VERSION}/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -d Resources/Models ]; then
  cp -R Resources/Models "$APP/Contents/Resources/Models"
  echo "Bundled models:"; ls "$APP/Contents/Resources/Models"
else
  echo "WARNING: no Resources/Models — app will fall back to Vision feature prints for faces"
fi

# Ad-hoc signature: required for the Photos permission prompt to work.
# (A Developer ID + notarization would remove the first-launch Gatekeeper warning.)
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "dist/PhotoForge-${VERSION}.zip"
ls -la dist
