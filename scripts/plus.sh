#!/bin/sh
# Copies telly's paid extras (downloads) in from a checkout of the private telly-apple-plus repo,
# for a build with them: add  OTHER_SWIFT_FLAGS='$(inherited) -DPLUS'  to xcodebuild.
# Without them (or the flag), telly builds as the free app.
# Usage: sh scripts/plus.sh [path to telly-apple-plus, default ../telly-apple-plus]
set -eu
plus=${1:-../telly-apple-plus}
here=$(cd "$(dirname "$0")/.." && pwd)
test -d "$plus/app" || { echo "No telly-apple-plus checkout at $plus" >&2; exit 1; }
rsync -a --delete --include='*.swift' --exclude='*' "$plus/app/" "$here/Telly/PlusPrivate/"
rsync -a --delete --include='*.swift' --exclude='*' "$plus/tests/" "$here/TellyTests/PlusPrivate/"
echo "Paid extras copied in. Build with OTHER_SWIFT_FLAGS='\$(inherited) -DPLUS'."
