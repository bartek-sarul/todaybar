#!/bin/sh
# builds TodayBar.app (menu-bar only, no Dock icon)
set -e
cd "$(dirname "$0")"
A=TodayBar.app/Contents
mkdir -p $A/MacOS
V=${VERSION:-0.0.0-dev}
# universal binary (arm64 + x86_64), macOS 14+
for a in arm64 x86_64; do
  swiftc -parse-as-library -O -target $a-apple-macos14.0 TodayBar.swift -o "${TMPDIR:-/tmp}/TodayBar-$a"
done
lipo -create "${TMPDIR:-/tmp}"/TodayBar-arm64 "${TMPDIR:-/tmp}"/TodayBar-x86_64 -output $A/MacOS/TodayBar
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TodayBar</string>
<key>CFBundleIdentifier</key><string>local.todaybar</string>
<key>CFBundleName</key><string>TodayBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Show today's events</string>
<key>NSRemindersFullAccessUsageDescription</key><string>Show today's reminders</string>
</dict></plist>
P
codesign --force --sign - TodayBar.app
