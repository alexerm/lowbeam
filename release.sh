#!/bin/sh
# Tests, builds, and zips Lowbeam for download. With SIGN_ID and NOTARY_PROFILE set
# (xcrun notarytool store-credentials NOTARY_PROFILE …), it also notarizes and staples.
set -e
cd "$(dirname "$0")"
./test.sh
./build.sh
V=$(cat VERSION)
mkdir -p dist
Z=dist/Lowbeam-$V.zip
ditto -c -k --keepParent Lowbeam.app "$Z"
if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$Z" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple Lowbeam.app
  ditto -c -k --keepParent Lowbeam.app "$Z"
  # Installer: a DMG with the app beside an Applications link, on dmg/background.tiff.
  D=dist/Lowbeam-$V.dmg
  rm -f "$D"
  create-dmg --volname "Lowbeam" --background dmg/background.tiff --window-size 640 400 \
    --icon-size 128 --icon Lowbeam.app 170 190 --app-drop-link 470 190 --hide-extension Lowbeam.app \
    --no-internet-enable "$D" Lowbeam.app
  codesign --sign "$SIGN_ID" --timestamp "$D"
  xcrun notarytool submit "$D" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$D"
  cp "$D" dist/Lowbeam.dmg   # stable name for the site's download link
else
  echo "not notarized: set SIGN_ID and NOTARY_PROFILE for a build other Macs will open"
fi
# Appcast for Sparkle: signs the zip with the "dimmer" EdDSA key in the login keychain.
# It lists this version only, with its download on the GitHub release v$V.
R=dist/appcast-$V
rm -rf "$R"; mkdir -p "$R"; cp "$Z" "$R/"
vendor/sparkle/bin/generate_appcast --account dimmer --download-url-prefix "https://github.com/alexerm/lowbeam/releases/download/v$V/" "$R"
cp "$Z" dist/Lowbeam.zip   # stable name for the site's download link
echo "release: $Z and $R/appcast.xml"
echo "publish: gh release create v$V \"$Z\" dist/Lowbeam.zip dist/Lowbeam-$V.dmg dist/Lowbeam.dmg \"$R/appcast.xml\" --title \"Lowbeam $V\""
