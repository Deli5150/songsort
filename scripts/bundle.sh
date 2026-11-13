#!/bin/sh
# Build a release SongSort.app into build/. Pass --install to copy it to /Applications.
set -eu
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="${VERSION:-$(cat VERSION)}"
APP="build/SongSort.app"

swift build -c release --product SongSort
BIN="$(swift build -c release --show-bin-path)/SongSort"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SongSort"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SongSort</string>
  <key>CFBundleDisplayName</key><string>SongSort</string>
  <key>CFBundleIdentifier</key><string>com.delvison.songsort</string>
  <key>CFBundleExecutable</key><string>SongSort</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/SongSort.app"
  cp -R "$APP" "/Applications/SongSort.app"
  echo "Installed /Applications/SongSort.app"
fi
