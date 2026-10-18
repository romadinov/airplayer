#!/bin/bash
# Builds Airplayer.app into ./build (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Airplayer.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Airplayer "$APP/Contents/MacOS/Airplayer"

# Icon: regenerate with `swift scripts/make-icon.swift Resources/AppIcon.iconset && iconutil -c icns Resources/AppIcon.iconset`
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Airplayer</string>
    <key>CFBundleDisplayName</key><string>Airplayer</string>
    <key>CFBundleIdentifier</key><string>com.romadinov.airplayer</string>
    <key>CFBundleExecutable</key><string>Airplayer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Airplayer streams video from this Mac to your AirPlay TV over the local network.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.avi</string>
                <string>org.matroska.mkv</string>
                <string>public.mpeg-4</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array><string>mkv</string><string>avi</string><string>mp4</string><string>m4v</string><string>mov</string><string>ts</string><string>m2ts</string><string>webm</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
