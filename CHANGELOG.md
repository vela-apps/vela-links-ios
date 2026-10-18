## 1.0.2

Small fixes and clearer notes.

- Fixed: a screen shown while tracking was switched off (for example before the person agreed) was remembered as already reported,
  so it was missed after they agreed. It is now reported the next time it is shown after tracking is on.
- Clearer notes on `createLink`: param values are text, numbers or booleans; the service refuses nested arrays and dictionaries.
- README: an app extension must pass `appId:` (the parent app's bundle id) and, to share the install id with the app, a shared
  `userDefaults:` suite. The update note now says plainly that anyone who updates to the first release with the SDK reports
  `first_open` and `session_start` once, so the new-installs figure rises for that release.

## 1.0.1

Fixes and a privacy manifest.

- Fixed: when an app asked for consent first, a new install could miss its `first_open` after the person agreed, on that launch or a
  later one. `first_open` is now sent once per install whenever tracking is on, it is marked once-only for the service, and an app
  closed before it was saved, or between saving and noting it, still sends exactly one. The old "this install already ran an earlier
  version" shortcut is gone, so a person updating from a build without the SDK sends `first_open` and `session_start` once.
- Fixed: a link handed to `handle(url:)` before `configure` had finished was lost. It is now kept and opened as soon as the SDK is ready.
- Events always go out under the person they were tracked for. Signing in, signing out or resetting can no longer move waiting
  events to someone else, a batch holds one person's events only, and a retried batch is sent exactly as before. A forced send now
  waits for a send that is already running.
- Amounts above 1,000,000,000 are dropped (the service refuses them); screen names are cut to 100 characters the way the service
  counts them; `resetUser()` called before the SDK started still makes a new install id.
- Added `PrivacyInfo.xcprivacy` (no tracking, the UserDefaults reason `CA92.1`, and the data types the SDK sends), included for both
  Swift Package Manager and CocoaPods.
- The package now compiles into app extensions, and builds with Swift's complete concurrency checking without errors.
- README: CocoaPods install by git tag, consent on every launch, debug bundle ids, the Team ID the link domain needs, and what
  updating from a build without the SDK reports.

## 1.0.0

First release of the native iOS SDK (Swift package `VelaLinks`, iOS 13 and newer).

- Receive links: Universal Links and custom-scheme links through `handle(url:)` / `handle(userActivity:)`, delivered to `onLink`
  closures and to the `links` `AsyncStream`; `consumePendingLink()` for a link that arrived before you listened; `resolve(url:)` to
  await the result. Links must have the exact shape `/l/<slug>/<code>`; an optional `slug` ignores other apps' links.
- Deferred deep links on the first launch after install, from the clipboard token `vlink:XXXX` (at most 3 tries; the clipboard is
  only read when it holds text, and cleared only if nobody copied anything since).
- Open reports (`link` or `qr`), `createLink`.
- In-app analytics: `track`, `trackPurchase`, `trackScreen`, `setUserId`, `resetUser`, `setTrackingEnabled`, `flush`,
  `first_open` and `session_start` by themselves, once-only events, order ids, debounce, a persisted queue (200 events, 7 days), a
  back-off after failures, and batches that are re-sent with the same id.
- `.velaScreen("Name")` for SwiftUI and `velaTrackScreen()` / `VelaScreenViewController` for UIKit (no method swizzling).
- Storage in `UserDefaults` (keys start with `vela_links.`), lifecycle through `NotificationCenter`, no dependencies.
