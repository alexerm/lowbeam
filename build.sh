#!/bin/sh
# Builds a universal Dimmer.app (Apple silicon + Intel) and installs it to ~/Applications.
# SIGN_ID="Developer ID Application: …" ./build.sh signs for distribution; without it the app is signed ad hoc.
set -e
cd "$(dirname "$0")"
V=$(cat VERSION)
A=Dimmer.app/Contents
rm -rf Dimmer.app .build/arm64 .build/x86_64
mkdir -p $A/MacOS $A/Resources .build
cp icon/Dimmer.icns $A/Resources/
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 Core.swift main.swift -o .build/Dimmer-$arch
done
lipo -create .build/Dimmer-arm64 .build/Dimmer-x86_64 -output $A/MacOS/Dimmer
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dimmer</string>
<key>CFBundleIdentifier</key><string>com.alexerm.dimmer</string>
<key>CFBundleName</key><string>Dimmer</string>
<key>CFBundleIconFile</key><string>Dimmer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocationUsageDescription</key><string>Dimmer uses your location only to find today's sunset time.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Dimmer uses your location only to find today's sunset time.</string>
</dict></plist>
P
if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" Dimmer.app
else
  codesign --force -s - Dimmer.app
fi
rm -rf ~/Applications/Dimmer.app && cp -R Dimmer.app ~/Applications/
echo "built Dimmer $V"
