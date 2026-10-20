# telly for iPad

telly plays your own IPTV subscription (Xtream Codes or an M3U playlist) on iPad. It's a native SwiftUI app.

- **Playback:** Apple's player for HLS and MP4; VLCKit for MKV, AVI and raw MPEG-TS.
- **Privacy:** your login stays in the iPad's Keychain and is only ever sent to your provider.
- **Sync:** optional (hidden for now), uses the same end-to-end-encrypted format as the Fire TV and Mac apps. See [telly-sync](https://github.com/tellyteam/telly-sync).

## Build

You need Xcode 26 or later.

```bash
scripts/fetch-vlckit.sh                         # MobileVLCKit (LGPL-2.1), checked against its published checksum
open Telly.xcodeproj
```

## Install on your iPad (free, no Apple Developer account)

1. In Xcode → Settings → Accounts, add your Apple ID. A free "Personal Team" is fine.
2. Select the **Telly** target → Signing & Capabilities, and choose that team under Team. If Xcode says the bundle id is taken, change it to something unique, for example `io.github.tellyteam.telly.yourname`.
3. Plug in the iPad, trust the computer, and turn on Developer Mode on the iPad (Settings → Privacy & Security → Developer Mode; the iPad restarts).
4. Choose the iPad as the run destination and press Run (⌘R).
5. The first time, on the iPad open Settings → General → VPN & Device Management and trust your developer certificate.

Apps signed with a free account stop opening after 7 days. To renew, plug the iPad in and press Run again; your login, lists and progress are kept.

**Don't commit the Team setting.** Xcode writes your team id into `project.pbxproj`; leave that change out of commits.

## Test

```bash
xcodebuild test -project Telly.xcodeproj -scheme Telly -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)'
```

## Licence

GPL-3.0-only. VLCKit is LGPL-2.1 (`Vendor/MobileVLCKit-COPYING.txt` once fetched).
