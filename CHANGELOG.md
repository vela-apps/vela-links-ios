## 1.2.0

- **Push opens.** `trackPushOpen(userInfo)` reads a Vela push's `vela_campaign`, `vela_route` and `vela_params`, records the `push_open`
  event with the campaign id (what the push report counts as an open) and returns a `VelaPushOpen` with the route and its values. The same
  push handed over twice is counted once in the process: it is known by the service's `vela_send_id` in the push data, else by
  `gcm.message_id` (or the `messageId` you pass), else the same campaign within 10 minutes counts once.
- **Consent read-back.** `setIdentityToken(_:)` now also reads the person's own consent answers from Vela Links
  (`POST /v1/users/consent/state`), so `consentOf` shows what is really recorded after a sign-in again or on a new phone. `refreshConsent()`
  does it on demand. An answer given on this phone and not delivered yet (or chosen while the read was on its way) wins, and an answer
  that arrives after a sign-out is dropped. An older server is ignored and nothing changes.
- **Offers on by default.** `offersDefaultOn` is the app's "offers on by default" setting, read with the consent answers (false until read
  and with a server that does not send it); `offersEnabled(_:)` is `consentOf(channel) ?? offersDefaultOn`.
- **No more paste notice.** Links on iPhone go straight to the App Store (no token is copied), so the first-launch check no longer reads the
  clipboard. An app with no App Store address in the dashboard can pass `configure(..., clipboardMatch: true)` to keep reading it.
- **Better install matching.** The first-launch check sends the screen size in points (`screen_width`, `screen_height`, portrait),
  `pixel_ratio` (`UIScreen.scale`), the time zone (`timezone`, IANA), the language (`language`, such as `en-IN`) and the iOS version
  (`os_version`), which the service uses to tell apart taps from the same network (a match may come back with `method: "signals"`).
- **The install id goes with the match and the open report** (`iid`), so the service remembers which install claimed a tap and counts one
  open per install and link. Only while tracking is on: never with `trackEvents: false` or after `setTrackingEnabled(false)`.
- **The link lookup is signed.** `GET /v1/links/{slug}/{code}` now carries `X-Api-Key` and `X-App-Id` like every other call, so the service
  can require the key later. A key only reads its own app's links: a link of another app is "not found" (already ignored with `slug`). A
  signed lookup refused with 401 (for example a debug or staging build whose bundle id is not saved in the dashboard) is tried once more
  unsigned, so links keep opening there.
- **`VelaLink.clickId` and `VelaLink.utm`** carry the click id and utm values (`click_id` and the `utm` object of the answer) when a newer
  server sends them with a first-launch match.
- **Push tokens:** Vela sends through Firebase only, so register the FCM token. `registerPushToken(_:provider: "apns")` now logs a warning,
  and `registerPushToken(apnsDeviceToken:)` is deprecated (it still works).
- Calls made before `configure` has finished were already kept (up to 100) and run in order; nothing changes there.

## 1.1.0

New in 1.1.0: identity, consent and push tokens, shopping events, and in-app messages (a bottom sheet or full screen, with a picture or video, drawn by the SDK). Everything is optional: an app that changes nothing works exactly as before.

- **Signed identity.** `setIdentityToken(_:)` takes the token your own server signs when someone signs in (the app never holds the secret).
  It is kept on the phone, sent with events (`identity_token`) and with everything below, and cleared by `resetUser()`.
- **Facts about the person.** `setUserProperties(_:locale:timezone:quietStart:quietEnd:)` sends plain labels, numbers and yes/no (up to 20) with
  the phone's language. Names that sound personal and values that look like a phone number or an email are dropped on the phone. Only what
  changed is sent.
- **Push token and consent.** `registerPushToken(_:provider:)` (`fcm` by default, `apns` for the raw token, or `registerPushToken(apnsDeviceToken:)`)
  and `setConsent(_:granted:policyVersion:purpose:source:)` with `consentOf(_:purpose:)`. Kept on the phone until delivered (offline-safe,
  survive a restart), sent only with an identity, never sent twice, forgotten when tracking is switched off or the user is reset.
- **Signing out.** `resetUser()` first asks the service to unlink the push token from the person (waiting at most 3 seconds, ignoring any
  failure), so offers meant for them do not reach the next person on the phone. Nothing is sent if no token was ever given.
- **Shopping events.** `trackAddToCart`, `trackRemoveFromCart`, `trackBeginCheckout`, `trackViewItem`, `trackSignup`, `trackLogin`.
- **In-app messages.** The SDK asks the service for a message at start, on return from the background (after 5 minutes away), after an event and on a
  screen, draws it over the active scene in a window of its own (UIKit and SwiftUI apps, bottom sheet or full screen, picture or muted video with
  its poster as the fallback), reports shown / clicked / dismissed / video progress (`shown` the moment it is on the screen) and hands a button's page
  to `onLink` / `links`. `setQuietScreens`, `pauseMessages()` / `resumeMessages()`, `InAppStyle` (passed to `configure`) and
  `setInAppMessageHandler` let the app keep control. Dynamic Type, dark mode, VoiceOver and Reduce Motion are respected.
- After an event or a screen the SDK asks only when the service says a live message waits for it (`trigger_events`, `trigger_screens`, kept 10 minutes).
- `installId` shows this phone's id (to register a test phone in the dashboard). `flush()` also sends the waiting person data.
- `PrivacyInfo.xcprivacy`: the push token and facts the app chooses to send are covered (device id, user id and other data, for the developer's own
  messages as well as analytics). A push token is collected only if the app passes one.
- New system framework: AVFoundation (for video).

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
