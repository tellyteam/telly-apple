# telly privacy policy

telly is a player for the TV subscription you already have from your provider. It has no accounts, no adverts, no analytics and no tracking. This policy covers every telly app: iPhone, iPad and Mac, Fire TV and Android, and LG TVs.

telly is a trading name of Nicholas JP Limited, which is responsible for your data under UK data protection law. Contact: [privacy@gettelly.app](mailto:privacy@gettelly.app).

## In short

- telly doesn't know who you are. There's nothing to sign up for.
- What you watch, your progress and your lists stay on your devices.
- Your provider login stays on the device you typed it on.
- Sync is optional and end-to-end encrypted: the relay that carries it can't read it.
- telly Plus is bought through Apple or Paddle. telly never sees your card or email.

## What stays on your device

- **Your provider's address and login.** Kept in the device's secure storage (the Keychain on Apple devices, encrypted storage on Android), never in backups, and never sent anywhere except to your provider.
- **Your provider's lists and artwork**, saved so telly opens quickly.
- **Your watch progress, Continue watching, My List, history and settings.**
- **Downloads**, on iPhone, iPad and Mac with telly Plus.

None of this leaves the device unless you turn on sync, and then only sealed, as below.

## Who telly talks to

- **Your provider.** telly connects to the provider address you enter, to sign in, get your lists and play. Artwork comes from wherever your provider's lists say it is, which can be another website. Those sites see your device's internet address, as any website would.
- **The sync relay** (sync.gettelly.app), only if you turn on sync.
- **Apple's App Store**, to buy or restore telly Plus on Apple devices.
- **Paddle**, if you buy telly Plus from a TV. You pay on your phone, on Paddle's checkout.
- **GitHub**, for update checks: telly for Fire TV and Android checks for a new version, and so does telly for Mac when it's downloaded from GitHub rather than the App Store. These checks send nothing about you.

telly uses no analytics, crash-reporting, advertising or tracking services.

## Sync

When you turn on sync, your devices share progress, Continue watching and My List through telly's relay. Each device seals what it shares with a key made from your household's link code, which never leaves your devices. The relay stores the sealed boxes and can't open them.

The relay keeps, for each household that syncs:

- a household id and a hash of its access token, both made from the link code;
- a random id for each device, and that device's sealed box;
- the day each box was last updated, not the time.

It never keeps request logs, internet addresses or times of day, and it never receives your provider login or what you watch. Boxes not updated for 90 days are deleted, and **Stop syncing** deletes that device's box straight away. The full detail is in the relay's [no-logs policy](https://github.com/tellyteam/telly-sync/blob/main/PRIVACY.md).

## telly Plus

telly Plus (sync, and downloads on Apple devices) is a yearly subscription for a whole household.

- **On iPhone, iPad and Mac** it's sold by Apple. Apple handles the payment under [its own privacy policy](https://www.apple.com/legal/privacy/). Your device shows the relay Apple's signed proof of purchase, so every device in your household gets telly Plus.
- **On a TV** it's sold by [Paddle](https://www.paddle.com), which takes the payment, handles tax and sends your receipt. Paddle has your email and payment details under [its own privacy policy](https://www.paddle.com/legal/privacy). Paddle tells the relay only that a subscription is paid, until when, and when it ends.

For telly Plus, the relay keeps a hash of the purchase's id (never the id itself), the last day it's paid for, and whether it was a test purchase. For a purchase made through Paddle, it also keeps a hash of each payment's transaction number for a year after the payment runs out, so you can move telly Plus to a new household with your receipt.

## Why telly can use this data

To provide what you've asked for: syncing your devices and the subscription you've bought (UK GDPR Article 6(1)(b)).

## Your rights

You can ask to see, correct or delete data about you, or object to how it's used, by emailing [privacy@gettelly.app](mailto:privacy@gettelly.app). Because telly has no accounts, the quickest way to delete your sync data is **Stop syncing** on each device. You can also complain to the [Information Commissioner's Office](https://ico.org.uk).

## Children

telly isn't aimed at children and doesn't knowingly collect anything from them.

## Changes

Any change to this policy is made in this file, in public, before the apps change. The date below is when it last changed.

Last updated: 5 November 2026.
