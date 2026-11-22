#!/bin/sh
# Tests, builds, and zips Dimmer for download. With SIGN_ID and NOTARY_PROFILE set
# (xcrun notarytool store-credentials NOTARY_PROFILE …), it also notarizes and staples.
set -e
cd "$(dirname "$0")"
./test.sh
./build.sh
V=$(cat VERSION)
mkdir -p dist
Z=dist/Dimmer-$V.zip
ditto -c -k --keepParent Dimmer.app "$Z"
if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$Z" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple Dimmer.app
  ditto -c -k --keepParent Dimmer.app "$Z"
else
  echo "not notarized: set SIGN_ID and NOTARY_PROFILE for a build other Macs will open"
fi
# Appcast for Sparkle: signs the zip with the "dimmer" EdDSA key in the login keychain.
# It lists this version only, with its download on the GitHub release v$V.
R=dist/appcast-$V
rm -rf "$R"; mkdir -p "$R"; cp "$Z" "$R/"
vendor/sparkle/bin/generate_appcast --account dimmer --download-url-prefix "https://github.com/alexerm/dimmer/releases/download/v$V/" "$R"
echo "release: $Z and $R/appcast.xml"
echo "publish: gh release create v$V \"$Z\" \"$R/appcast.xml\" --title \"Dimmer $V\""
