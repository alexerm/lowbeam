#!/bin/sh
set -e
cd "$(dirname "$0")"
A=Dimmer.app/Contents
mkdir -p $A/MacOS
mkdir -p $A/Resources && cp icon/Dimmer.icns $A/Resources/
swiftc -O main.swift -o $A/MacOS/Dimmer
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dimmer</string>
<key>CFBundleIdentifier</key><string>com.alexerm.dimmer</string>
<key>CFBundleName</key><string>Dimmer</string>
<key>CFBundleIconFile</key><string>Dimmer</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocationUsageDescription</key><string>Dimmer uses your location only to find today's sunset time.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Dimmer uses your location only to find today's sunset time.</string>
</dict></plist>
P
codesign -s - --force Dimmer.app
rm -rf ~/Applications/Dimmer.app && cp -R Dimmer.app ~/Applications/
echo built
