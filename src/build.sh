#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="${STAGE:-/private/tmp/claude-501/-Users-boris-s-Documents-Claude-Tasks/b044dd50-15d9-42cc-8ec6-2e889c1c6bd9/scratchpad/oigs}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
APP="$STAGE/Open in Google Sheets.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"

echo "→ compiling"
swiftc -O -target arm64-apple-macos13.0 \
  -o "$C/MacOS/OpenInSheets" src/main.swift \
  -framework AppKit -framework CoreServices -framework ServiceManagement

echo "→ resources"
cp build/AppIcon.icns          "$C/Resources/AppIcon.icns"
cp build/icons/menubar.png     "$C/Resources/menubar.png"
cp build/icons/menubar@2x.png  "$C/Resources/menubar@2x.png"
cp "$HOME/bin/rclone"          "$C/Resources/rclone"
chmod +x "$C/Resources/rclone"

cat > "$C/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Open in Google Sheets</string>
  <key>CFBundleDisplayName</key><string>Open in Google Sheets</string>
  <key>CFBundleIdentifier</key><string>com.madetask.OpenInSheets</string>
  <key>CFBundleExecutable</key><string>OpenInSheets</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Internal tool</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Excel Workbook</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>org.openxmlformats.spreadsheetml.sheet</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Excel 97-2004 Workbook</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.microsoft.excel.xls</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$C/PkgInfo"

echo "→ signing"
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$C/Resources/rclone"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo "→ registering"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "✓ $APP"
