#!/bin/zsh
# Build, sign (Developer ID), notarize and staple IQ Coach as a DMG.
# Prerequisites, done once by the account holder (see docs/DISTRIBUTION-PLAN.md):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. xcrun notarytool store-credentials iqcoach-notary --apple-id <Apple ID> --team-id FK6E9XBY6Y
# Usage: scripts/package-mac.sh            (full run)
#        scripts/package-mac.sh --no-notary (sign and package only, for a dry run)
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARY=1; [[ "${1:-}" == "--no-notary" ]] && NOTARY=0
PROFILE=iqcoach-notary
VER=$(grep MARKETING_VERSION project.yml | head -1 | awk -F'"' '{print $2}')
OUT=build/release
APP="$OUT/export/IQCoach.app"
DMG="$OUT/IQCoach-$VER.dmg"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No 'Developer ID Application' certificate in the keychain. Create it in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
fi
if (( NOTARY )) && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarytool profile '$PROFILE'. Run: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id FK6E9XBY6Y" >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate
xcodebuild -project IQCoach.xcodeproj -scheme IQCoach -configuration Release \
  -archivePath "$OUT/IQCoach.xcarchive" archive | tail -3
xcodebuild -exportArchive -archivePath "$OUT/IQCoach.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$OUT/export" | tail -3

echo "== checks"
if ls "$APP/Contents/MacOS" | grep -qE 'debug\.dylib|__preview'; then echo "debug dylibs present" >&2; exit 1; fi
[[ -d "$APP/Contents/PlugIns" ]] && { echo "PlugIns present (test bundle?)" >&2; exit 1; }
codesign -vvv --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|Timestamp=|flags=.*runtime"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | tee "$OUT/entitlements.txt"
grep -q get-task-allow "$OUT/entitlements.txt" && { echo "get-task-allow present" >&2; exit 1; }
lipo -archs "$APP/Contents/MacOS/IQCoach"

if (( NOTARY )); then
  echo "== notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/IQCoach-upload.zip"
  xcrun notarytool submit "$OUT/IQCoach-upload.zip" --keychain-profile "$PROFILE" --wait --timeout 2h
  xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
fi

echo "== DMG"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/IQCoach.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "IQ Coach" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
codesign -s "Developer ID Application" --timestamp -i com.allisonbowman.iqcoach.dmg "$DMG"
if (( NOTARY )); then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --timeout 2h
  xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG"
  spctl -a -vvv -t exec "$APP"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
fi
echo "done: $DMG"
