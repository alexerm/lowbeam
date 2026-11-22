#!/bin/sh
# Builds a universal Lowbeam.app (Apple silicon + Intel) and installs it to ~/Applications.
# SIGN_ID="Developer ID Application: …" ./build.sh signs for distribution; without it the app is signed ad hoc.
set -e
cd "$(dirname "$0")"
V=$(cat VERSION)
A=Lowbeam.app/Contents
rm -rf Lowbeam.app .build/arm64 .build/x86_64
mkdir -p $A/MacOS $A/Resources $A/Frameworks .build
ditto vendor/sparkle/Sparkle.framework $A/Frameworks/Sparkle.framework
cp icon/Lowbeam.icns $A/Resources/
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 -F vendor/sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks Core.swift Keyboard.swift main.swift -o .build/Lowbeam-$arch
done
lipo -create .build/Lowbeam-arm64 .build/Lowbeam-x86_64 -output $A/MacOS/Lowbeam
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Lowbeam</string>
<key>CFBundleIdentifier</key><string>com.alexerm.dimmer</string>
<key>CFBundleName</key><string>Lowbeam</string>
<key>CFBundleIconFile</key><string>Lowbeam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSUIElement</key><true/>
<key>SUFeedURL</key><string>https://github.com/alexerm/lowbeam/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>s3DIRfwSf50GG38c49P48h090mQSIqisLQhjputTVlM=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocationUsageDescription</key><string>Lowbeam uses your location only to find today's sunset time.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Lowbeam uses your location only to find today's sunset time.</string>
</dict></plist>
P
if [ -n "$SIGN_ID" ]; then
  # Sparkle's helpers first, inside out, then the app (Sparkle's documented order for Developer ID).
  F=$A/Frameworks/Sparkle.framework/Versions/B
  for x in "$F/XPCServices/Installer.xpc" "$F/XPCServices/Downloader.xpc" "$F/Autoupdate" "$F/Updater.app" "$A/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp -s "$SIGN_ID" "$x"
  done
  codesign --force --options runtime --timestamp -s "$SIGN_ID" Lowbeam.app
else
  codesign --force --deep -s - Lowbeam.app
fi
rm -rf ~/Applications/Lowbeam.app && cp -R Lowbeam.app ~/Applications/
echo "built Lowbeam $V"
