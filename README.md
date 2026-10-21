# telly for iPad and Mac

A small, fast IPTV player for iPad and Mac. Bring your own provider (Xtream Codes or an M3U
playlist); telly gives you a clean way to watch it. One native SwiftUI codebase builds both apps.

- **Home** with Pick up where you left off, Continue watching and My List
- **Live TV**, **films** and **series**, with detail pages, seasons and episodes
- **Picks up where you left off**, including the next episode once the credits roll
- **Plays almost anything:** Apple's player for HLS and MP4, and [VLCKit](https://code.videolan.org/videolan/VLCKit)
  for MKV, AVI and raw MPEG-TS (including films without an index, and audio and subtitle tracks)
- **On a Mac:** the player fills the window or the screen (<kbd>F</kbd> or double-click),
  <kbd>Space</kbd> pauses, <kbd>←</kbd> <kbd>→</kbd> skip 10 seconds, <kbd>↑</kbd> <kbd>↓</kbd> change channel,
  <kbd>Esc</kbd> closes

telly contains no channels or content. You need your own subscription from an IPTV provider.

telly is also on [Android TV and Fire TV](https://github.com/tellyteam/telly-android) and
[LG TVs](https://github.com/tellyteam/telly-lg).

## Privacy

- telly talks only to your provider. No accounts, analytics, adverts or tracking.
- Your provider login is kept in the device's Keychain. History, progress and My List stay on the device.
- Plain HTTP is refused unless you allow it for your provider (some providers have no HTTPS).

## Build

You need Xcode 26 or later.

```bash
scripts/fetch-vlckit.sh   # MobileVLCKit (iPad) and VLCKit (Mac), LGPL-2.1, checked against VideoLAN's published checksums
open Telly.xcodeproj
```

The **Telly** scheme builds the iPad app and **Telly Mac** the Mac app.

## Install on your Mac

Choose the **Telly Mac** scheme and **My Mac**, and press Run (⌘R), or build it from the terminal:

```bash
xcodebuild -project Telly.xcodeproj -scheme "Telly Mac" -configuration Release -derivedDataPath build/mac build
open build/mac/Build/Products/Release/telly.app
```

## Install on your iPad (free, no Apple Developer account)

1. In Xcode → Settings → Accounts, add your Apple ID. A free "Personal Team" is fine.
2. Select the **Telly** target → Signing & Capabilities, and choose that team under Team. If Xcode says the bundle id is taken, change it to something unique, for example `io.github.tellyteam.telly.yourname`.
3. Plug in the iPad, trust the computer, and turn on Developer Mode on the iPad (Settings → Privacy & Security → Developer Mode; the iPad restarts).
4. Choose the iPad as the run destination and press Run (⌘R).
5. The first time, on the iPad open Settings → General → VPN & Device Management and trust your developer certificate.

Apps signed with a free account stop opening after 7 days. To renew, plug the iPad in and press Run again; your login, lists and progress are kept.

**Don't commit the Team setting.** Xcode writes your team id into `project.pbxproj`; leave that change out of commits.

## How it's organised

| Path | What's there |
|---|---|
| `Telly/Data/` | Provider parsing (Xtream, M3U), the catalogue cache, Keychain and storage |
| `Telly/Player/` | One player with two engines: Apple's (AVPlayer) and VLCKit |
| `Telly/Views/` | The interface, shared by iPad and Mac |
| `Telly/App/Platform.swift` | What differs between iPad and Mac |
| `Telly/Assets.xcassets` | The wordmark and icons, drawn by [telly-brand](https://github.com/tellyteam/telly-brand) |

## Test

```bash
xcodebuild test -project Telly.xcodeproj -scheme Telly -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)'
```

## Licence

GPL-3.0-only. VLCKit is LGPL-2.1 (`Vendor/*-COPYING.txt` once fetched).
