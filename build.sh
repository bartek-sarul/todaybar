#!/bin/sh
# builds TodayBar.app (menu-bar only, no Dock icon)
set -e
cd "$(dirname "$0")"
A=TodayBar.app/Contents
mkdir -p $A/MacOS
swiftc -parse-as-library -O TodayBar.swift -o $A/MacOS/TodayBar
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TodayBar</string>
<key>CFBundleIdentifier</key><string>local.todaybar</string>
<key>CFBundleName</key><string>TodayBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Show today's events</string>
<key>NSRemindersFullAccessUsageDescription</key><string>Show today's reminders</string>
</dict></plist>
P
codesign --force --sign - TodayBar.app
