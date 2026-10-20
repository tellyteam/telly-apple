#!/bin/sh
# Fetches MobileVLCKit (LGPL-2.1) from VideoLAN's official CocoaPods mirror and checks it against
# the checksum in the official podspec. telly uses it for MKV, AVI and raw MPEG-TS, which Apple's
# player can't open.
set -eu
VERSION_URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz"
SHA256="c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52"
cd "$(dirname "$0")/.."
[ -d Vendor/MobileVLCKit.xcframework ] && { echo "MobileVLCKit is already in Vendor/"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fSL -o "$tmp/vlckit.tar.xz" "$VERSION_URL"
echo "$SHA256  $tmp/vlckit.tar.xz" | shasum -a 256 -c -
tar -xf "$tmp/vlckit.tar.xz" -C "$tmp"
mkdir -p Vendor
mv "$tmp/MobileVLCKit-binary/MobileVLCKit.xcframework" Vendor/
cp "$tmp/MobileVLCKit-binary/COPYING.txt" Vendor/MobileVLCKit-COPYING.txt
echo "MobileVLCKit is in Vendor/"
