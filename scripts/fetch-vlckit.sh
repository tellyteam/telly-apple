#!/bin/sh
# Fetches VLCKit (LGPL-2.1) from VideoLAN's official CocoaPods mirror and checks each against the
# checksum in its official podspec: MobileVLCKit for iPad, VLCKit for Mac. telly uses them for MKV,
# AVI and raw MPEG-TS, which Apple's player can't open.
set -eu
cd "$(dirname "$0")/.."
mkdir -p Vendor

# fetch NAME URL SHA256 DIR_IN_ARCHIVE
fetch() {
  if [ -d "Vendor/$1.xcframework" ]; then echo "$1 is already in Vendor/"; return; fi
  tmp=$(mktemp -d)
  curl -fSL -o "$tmp/vlckit.tar.xz" "$2"
  echo "$3  $tmp/vlckit.tar.xz" | shasum -a 256 -c -
  tar -xf "$tmp/vlckit.tar.xz" -C "$tmp"
  mv "$tmp/$4/$1.xcframework" Vendor/
  cp "$tmp/$4/COPYING.txt" "Vendor/$1-COPYING.txt"
  rm -rf "$tmp"
  echo "$1 is in Vendor/"
}

fetch MobileVLCKit https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz \
  c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52 MobileVLCKit-binary
fetch VLCKit https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz \
  019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d "VLCKit - binary package"
