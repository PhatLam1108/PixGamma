#!/bin/bash
# Builds PixGamma.app (SwiftUI app + bundled `pixgamma` CLI + compiled Core ML models).
#   scripts/build.sh            → build/PixGamma.app
#   scripts/build.sh --install  → also copy to /Applications and link `pixgamma` into /opt/homebrew/bin
#   scripts/make_dmg.sh         → installer for a release (see that script)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# One version for app, CLI, API and installer: APIServer.version.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/PixGammaCore/APIServer.swift")"
FINAL="$ROOT/build/PixGamma.app"
# Desktop/Documents may be iCloud-synced, which re-adds Finder xattrs that break codesign,
# so the bundle is assembled and signed in a temporary folder first.
STAGE="$(mktemp -d)"
APP="$STAGE/PixGamma.app"
trap 'rm -rf "$STAGE"' EXIT
cd "$ROOT"

echo "▸ swift build (release)"
swift build -c release --product PixGammaApp
swift build -c release --product pixgamma
BIN="$(swift build -c release --show-bin-path)"

echo "▸ Đóng gói $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Models"
cp "$BIN/PixGammaApp" "$APP/Contents/MacOS/PixGammaApp"
cp "$BIN/pixgamma" "$APP/Contents/Helpers/pixgamma"

echo "▸ Compile model Core ML"
for pkg in "$ROOT"/Models/*.mlpackage; do
  name="$(basename "$pkg" .mlpackage)"
  xcrun coremlcompiler compile "$pkg" "$APP/Contents/Resources/Models" >/dev/null
  echo "  ✓ $name"
done

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PixGamma</string>
  <key>CFBundleDisplayName</key><string>PixGamma</string>
  <key>CFBundleIdentifier</key><string>vn.phatlam.pixora</string>
  <key>CFBundleExecutable</key><string>PixGammaApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▸ Ký ad-hoc"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP"

mkdir -p "$ROOT/build"
rm -rf "$FINAL"
ditto "$APP" "$FINAL"

if [ "${1:-}" = "--install" ]; then
  echo "▸ Cài vào /Applications"
  rm -rf /Applications/PixGamma.app
  ditto "$APP" /Applications/PixGamma.app
  # Pixora was the name up to 0.2.1: drop that copy, keep `pixora` as an alias of the CLI.
  rm -rf /Applications/Pixora.app
  ln -sf /Applications/PixGamma.app/Contents/Helpers/pixgamma /opt/homebrew/bin/pixgamma
  ln -sf /Applications/PixGamma.app/Contents/Helpers/pixgamma /opt/homebrew/bin/pixora
  echo "  CLI: $(command -v pixgamma)"
  # Recover (SD 1.5 + ControlNet Tile, ~2 GB) stays outside the bundle; link it where
  # ModelStore looks (Application Support/PixGamma/Models).
  if [ -e "$ROOT/Models/Recover" ]; then
    LEGACY="$HOME/Library/Application Support/Pixora"
    [ -d "$LEGACY" ] && [ ! -e "$HOME/Library/Application Support/PixGamma" ] && mv "$LEGACY" "$HOME/Library/Application Support/PixGamma"
    SUPPORT="$HOME/Library/Application Support/PixGamma/Models"
    mkdir -p "$SUPPORT"
    ln -sfn "$(cd "$ROOT/Models/Recover" && pwd -P)" "$SUPPORT/Recover"
    echo "  Recover: $SUPPORT/Recover"
  fi
fi

du -sh "$FINAL"
echo "✓ Xong: $FINAL"
