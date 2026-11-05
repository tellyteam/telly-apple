#!/bin/sh
# Builds telly for iPhone and iPad, with the paid extras, and uploads it to App Store Connect for
# TestFlight. Signing is automatic with your team; Xcode makes the certificates and profiles.
#
# Usage: TEAM_ID=ABCDE12345 sh scripts/testflight.sh 1.0.0 [path to telly-apple-plus]
#
# Signs in to App Store Connect with the Apple account in Xcode → Settings → Accounts, or with an
# App Store Connect API key if these are set:
#   ASC_KEY_PATH (the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID
#
# The build number is the time (202611051430 for 14:30 on 5 November 2026), so it always goes up.
set -eu
version=${1:?Usage: TEAM_ID=… sh scripts/testflight.sh <version, e.g. 1.0.0> [telly-apple-plus path]}
plus=${2:-../telly-apple-plus}
: "${TEAM_ID:?Set TEAM_ID to your Apple developer team id (developer.apple.com → Membership)}"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
build=$(date -u +%Y%m%d%H%M)
out="$here/build/testflight"
rm -rf "$out"
mkdir -p "$out"

auth=""
if [ -n "${ASC_KEY_PATH:-}" ]; then
  auth="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID ${ASC_KEY_ID:?} -authenticationKeyIssuerID ${ASC_ISSUER_ID:?}"
fi

test -d Vendor/MobileVLCKit.xcframework || sh scripts/fetch-vendor.sh
sh scripts/plus.sh "$plus"

# shellcheck disable=SC2086
xcodebuild -project Telly.xcodeproj -scheme Telly -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/telly.xcarchive" \
  -allowProvisioningUpdates $auth \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  OTHER_SWIFT_FLAGS='$(inherited) -DPLUS' \
  archive

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$out/telly.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" -allowProvisioningUpdates $auth

echo "Uploaded telly $version ($build). It shows in App Store Connect → TestFlight once Apple has processed it."
