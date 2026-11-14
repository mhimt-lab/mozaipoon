#!/bin/zsh
# Build "モザイぷーん.app" (universal: Apple silicon + Intel, ad-hoc signed) into ./build/.
# With --zip, also write build/Mozaipoon-<version>.zip for a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product WipeMosaic
BIN=$(swift build -c release "${ARCHS[@]}" --product WipeMosaic --show-bin-path)
VERSION=1.2.2

APP=build/モザイぷーん.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WipeMosaic" "$APP/Contents/MacOS/WipeMosaic"

# App icon: assets/icon/AppIcon.png (1024×1024, from AppIcon.svg via scripts/render-icon.mjs).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WipeMosaic</string>
  <key>CFBundleIdentifier</key><string>local.wipe-mosaic</string>
  <key>CFBundleName</key><string>モザイぷーん</string>
  <key>CFBundleDisplayName</key><string>モザイぷーん</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Movie</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/WipeMosaic"))"

if [[ "${1:-}" == "--zip" ]]; then
  ZIP=build/Mozaipoon-$VERSION.zip
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  echo "zip: $PWD/$ZIP"
fi
