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
