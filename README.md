# VelaLinks for iOS

Deep links, deferred deep links, short share links, QR codes, link tracking and **in-app analytics** for iOS apps, powered by the
[Vela Links](https://deeplinks.velaapps.in) service. A link opens the right screen in your app, even when the app is not installed
yet, and you see which links and campaigns bring people who sign up and pay.

**Needs:** iOS 13 or newer, Swift 5.9 or newer. Works from UIKit and SwiftUI. No third-party dependencies.

## Quick start

**1. Add your app in the dashboard.** Sign up at [deeplinks.velaapps.in](https://deeplinks.velaapps.in) (there is a free plan), add
your app (bundle id, Apple Team ID, store links) and copy the SDK key. The **SDK setup** tab shows the exact settings for your app,
and **Verify setup** checks them. Save both the iOS bundle id and the Apple Team ID: the link domain builds its
`apple-app-site-association` file from them (`<Team ID>.<bundle id>`), so Universal Links do not open your app until both are saved.

**2. Install.** In Xcode: File > Add Package Dependencies, and enter the repository address of this package. Or in `Package.swift`:
```swift
.package(url: "https://github.com/vela-apps/vela-links-ios.git", from: "1.1.0")
```
CocoaPods:
```ruby
pod 'VelaLinks', :git => 'https://github.com/vela-apps/vela-links-ios.git', :tag => '1.1.0'
```

**3. Start it** as early as you can (the app's `init` or `application(_:didFinishLaunchingWithOptions:)`):
```swift
import VelaLinks

Task {
    try await VelaLinks.configure(
        apiKey: "vl_...",
        baseUrl: "https://api.links.velaapps.in",
        slug: "your-app-slug"        // optional: ignore links that belong to another app
    )
}
```
Calls to `track` and friends made before `configure` has finished are kept in order and run when it finishes. They never crash. A
link handed to `handle(url:)` before `configure` has finished is kept (the newest one) and resolved as soon as it does.

**4. Send incoming links to the SDK and listen for them.**
```swift
VelaLinks.shared.onLink { link in
    // link.route, link.params, link.deferred
    guard ["/invite", "/product"].contains(link.route) else { return }   // ignore anything you do not expect
    router.open(link.route, params: link.params)
}
// or, with async/await:
for await link in VelaLinks.shared.links { ... }
```
If a link arrives before you listen, read it once with `VelaLinks.shared.consumePendingLink()`.

**5. Create a short link** to share anywhere:
```swift
let url = try await VelaLinks.shared.createLink(route: "/invite", params: ["id": "42"], title: "Join me")
```
Param values are text, numbers or booleans; nested arrays and dictionaries are refused by the service.

**6. See how people use your app.**
```swift
VelaLinks.shared.track("signup")
VelaLinks.shared.track("share", properties: ["channel": "whatsapp"])
VelaLinks.shared.trackPurchase(499, currency: "INR", orderId: "ORD-1001")
VelaLinks.shared.track("tutorial_done", once: true)      // once per person

await VelaLinks.shared.setUserId("user_123")             // after sign-in, your own id (not an email or phone number)
await VelaLinks.shared.resetUser()                        // on sign-out, when the next person should be a stranger
```
The dashboard's **Behaviour** tab shows active users, new installs, sessions, retention, your most used screens and events, funnels,
revenue, and which link or campaign brought the people who pay. `first_open` and `session_start` are reported for you.

## iOS setup

**Universal Links.** In Xcode, open your target's *Signing & Capabilities*, add *Associated Domains* and add
```
applinks:YOUR-LINK-DOMAIN
```
(the link domain shown in the dashboard, for example `my-day.links.velaapps.in`). The dashboard hosts the
`apple-app-site-association` file for you.

**Custom scheme (optional).** Under the target's *Info > URL Types*, add your URI scheme (for example `myday`). Links then look like
`myday://l/<slug>/<code>`.

### SwiftUI
```swift
@main
struct MyApp: App {
    init() {
        Task { try? await VelaLinks.configure(apiKey: "vl_...", baseUrl: "https://api.links.velaapps.in") }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { VelaLinks.shared.handle(url: $0) }                                   // custom scheme and links
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { VelaLinks.shared.handle(userActivity: $0) } // Universal Links
                .velaScreen("Home")                                                               // reports a screen when it appears
        }
    }
}
```
Put `.velaScreen("Name")` on each screen (not on dialogs or sheets). The same screen twice in a row is reported once.

### UIKit with a SceneDelegate
```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    // links that launched the app
    options.userActivities.forEach { VelaLinks.shared.handle(userActivity: $0) }
    options.urlContexts.forEach { VelaLinks.shared.handle(url: $0.url) }
}
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { VelaLinks.shared.handle(userActivity: userActivity) }
func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    contexts.forEach { VelaLinks.shared.handle(url: $0.url) }
}
```

### UIKit with an AppDelegate only
```swift
func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    VelaLinks.shared.handle(url: url)
}
func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    VelaLinks.shared.handle(userActivity: userActivity)
}
```
`handle` returns `true` when the URL has the shape of a Vela link; it resolves in the background and never blocks. The same address
handed over twice within 2 seconds counts once. Use `await VelaLinks.shared.resolve(url:)` instead if you want the resolved link
as a return value.

### Screens in UIKit
```swift
class ProductViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        velaTrackScreen("Product")     // or velaTrackScreen() for the class name
    }
}
```
Or subclass `VelaScreenViewController`. There is no method swizzling: you decide which controllers are screens.

## People, consent and push token
Everything here is optional, kept on the phone until delivered (so it works offline and survives a restart), and sent only when the person
is proven. **Your own server signs the identity token** when someone signs in (with the identity secret from the dashboard, which never goes
in the app); pass it on. Nothing about a person is sent without it.
```swift
await VelaLinks.shared.setUserId("user_123")                 // your own id
await VelaLinks.shared.setIdentityToken(tokenFromYourServer) // nil on sign-out (resetUser() clears it too)
await VelaLinks.shared.resetUser()                           // on sign-out: first unlinks the push token from the person (at most 3 s, errors ignored)

VelaLinks.shared.setUserProperties(["lang": "te", "orders": 3, "uses_business": true],
                                   timezone: "Asia/Kolkata", quietStart: 21, quietEnd: 8)

// Firebase:
VelaLinks.shared.registerPushToken(fcmToken)                 // provider defaults to "fcm"
// plain APNs, from application(_:didRegisterForRemoteNotificationsWithDeviceToken:):
VelaLinks.shared.registerPushToken(apnsDeviceToken: deviceToken)

VelaLinks.shared.setConsent("push", granted: true, policyVersion: "2026-10")   // returns false for invalid input
VelaLinks.shared.setConsent("inapp", granted: false, policyVersion: "2026-10", source: "settings_toggle")
let allowed = VelaLinks.shared.consentOf("push")             // true, false, or nil if never asked
print(VelaLinks.shared.installId ?? "")                      // register this phone for testing messages in the dashboard
```
Names that sound personal (phone, email, name, address, religion, health ...) and values that look like a phone number or an email are
dropped before anything is sent; up to 20 properties; `nil` removes one. Channels: `push`, `whatsapp`, `sms`, `email`, `inapp`; purposes:
`marketing` (default) or `service`. A withdrawal takes effect at once. The push token is collected only if you call `registerPushToken`.

Shopping events campaigns understand ("added to cart, did not order"):
```swift
VelaLinks.shared.trackAddToCart(items: 2, cartValue: 540, store: "gpn", category: "sweets")
VelaLinks.shared.trackRemoveFromCart(items: 1, store: "gpn")
VelaLinks.shared.trackBeginCheckout(items: 1, cartValue: 540, store: "gpn")
```

## In-app messages
The service decides who sees what and when; the SDK draws the message over the screen the person is using, in a window of its own, so
nothing changes in your views. It works the same for UIKit and SwiftUI apps and picks the active scene on an iPad. Messages are asked for
at app start, after the app comes back from more than 5 minutes away, after an event and on a screen, and the last two only when the
service says a live message waits for that event or screen. Never two at once, never while the app is in the background, the keyboard is
open or a system alert is up. Text, up to two buttons, a picture or a muted looping video with a poster picture. Layouts the SDK does not
know are ignored, and so is a message whose picture does not load.
```swift
// colours, corner radius, font (optional)
var style = InAppStyle(accent: InAppColor(hex: 0xC2185B), cornerRadius: 24, fontName: "Poppins-Regular")
try await VelaLinks.configure(apiKey: "vl_...", baseUrl: "...", inAppStyle: style)

VelaLinks.shared.setQuietScreens(["Payment", "Otp"])   // matched from the start of the screen name you report
VelaLinks.shared.pauseMessages()                        // a game, a video, a payment ...
VelaLinks.shared.resumeMessages()                       // each pause needs a resume
```
Screen names come from `.velaScreen("Name")` (SwiftUI) or `velaTrackScreen("Name")` (UIKit). A button either closes the message or opens a page
you declared in the dashboard: the SDK hands it to your `onLink` closure (or the `links` stream) like a link that opened the app, with
`campaign == "inapp"`:
```swift
VelaLinks.shared.onLink { link in router.open(link.route, params: link.params) }
```
To draw messages yourself, set a handler (main thread). Report what happens with the reporter; your handler opens the page:
```swift
VelaLinks.shared.setInAppMessageHandler { message, reporter in
    reporter.markShown()
    // ... show message.title, message.body, message.media, message.buttons in your own UI ...
    reporter.markClicked(0)        // or reporter.markDismissed()
    router.open(message.buttons[0].route ?? "/")
}
VelaLinks.shared.setInAppMessageHandler(nil)   // back to the SDK's own look
```
Dynamic Type, dark mode (`InAppStyle.dark`, with `darkSurface` / `darkText` overrides), VoiceOver (the picture's description is read, the
two-finger Z gesture closes) and Reduce Motion (no sliding, the poster instead of the video) are respected. The person's answer to the
`inapp` consent channel is applied by the service.

## Consent first
By default `first_open` and `session_start` are queued as soon as `configure` runs. If you must ask first:
```swift
try await VelaLinks.configure(apiKey: "vl_...", baseUrl: "...", trackEvents: false)
// later, when the person agrees:
await VelaLinks.shared.setTrackingEnabled(true)     // also starts first_open and session_start
```
`setTrackingEnabled(false)` discards waiting events and stops new ones; the choice is remembered. It stops in-app events only: link
opens still resolve and are counted unless you pass `reportOpens: false`. `autoTrack: false` turns off only the automatic events.

**Pass `trackEvents` from the person's stored choice on every launch.** A saved opt-in does not override `trackEvents: false`, so an
app that always passes `false` never collects anything after a restart until it calls `setTrackingEnabled(true)` again. A saved
opt-out does win over `trackEvents: true`.
```swift
let agreed = UserDefaults.standard.bool(forKey: "analyticsConsent")      // your own record of the person's answer
try await VelaLinks.configure(apiKey: "vl_...", baseUrl: "...", trackEvents: agreed)
```
`first_open` is reported once per install, as soon as tracking is on and it has not been sent: also when the person agrees on a later
launch, and when the app was closed before it could be saved.

## Reference
| Call | What it does |
| --- | --- |
| `VelaLinks.configure(apiKey:baseUrl:slug:matchDeferred:reportOpens:trackEvents:autoTrack:requestTimeout:appId:userDefaults:inAppStyle:)` | Starts the SDK (throws for an empty key or an insecure base URL). |
| `shared.onLink { }` / `shared.links` | Links that open the app: a closure (main thread) or an `AsyncStream`. |
| `shared.consumePendingLink()` | The link that arrived before anyone listened, once. |
| `shared.handle(url:)` / `handle(userActivity:)` | Give the SDK a URL or Universal Link from the system. |
| `shared.resolve(url:)` | Resolve a link URL and return it. |
| `shared.createLink(route:params:title:...)` | Make a short link (`async throws`). |
| `shared.track(_:properties:once:)`, `trackPurchase(_:currency:orderId:properties:)`, `trackScreen(_:)` | Events. Never throw, never block. |
| `shared.setUserId(_:)`, `resetUser()`, `setTrackingEnabled(_:)`, `trackingEnabled`, `flush()` | Identity, consent and sending. |
| `shared.setIdentityToken(_:)`, `setUserProperties(_:...)`, `registerPushToken(_:provider:)`, `setConsent(_:granted:policyVersion:...)`, `consentOf(_:purpose:)`, `installId` | People, push token and consent (see above). |
| `shared.trackAddToCart(...)`, `trackRemoveFromCart(...)`, `trackBeginCheckout(...)`, `trackViewItem(...)`, `trackSignup(...)`, `trackLogin(...)` | Standard shopping events. |
| `shared.setQuietScreens(_:)`, `pauseMessages()`, `resumeMessages()`, `setInAppMessageHandler(_:)` | In-app message controls. |
| `shared.shutdown()` | Stop listening, send what is waiting, end the streams. |

## Good to know
- **The SDK key** identifies your app. With it the SDK creates links, reports opens, sends in-app events and asks the service to match
  an install to a link, and it cannot do anything else. It lives in your app like an analytics key, so it is rate-limited, and you can
  rotate it in the dashboard at any time.
- **Revenue is client-reported.** Anyone who copies the key out of your app could send fake events, so verify real purchases on your
  own server. The bundle id check only guards against mistakes, because the app sends the id itself.
- **Debug builds and other bundle ids:** every call that carries the key also carries your app's bundle id (`X-App-Id`). When the
  dashboard has an iOS bundle id saved, the service answers 401 "This SDK key belongs to a different app" to any other id, for example
  a debug or beta build with its own bundle id. Events are then kept and retried (nothing is sent) and `createLink` throws. Either save
  the id in the dashboard, or pass `appId: "your.saved.bundle.id"` to `configure`.
- **Treat `link.route` and `link.params` as untrusted input,** like any deep link: check the route against the screens you allow, and
  never put secrets in link params.
- **Event rules:** names use letters, digits and `_` (2 to 40 characters, starting with a letter). Up to 10 properties with short
  text (100 characters), finite numbers or true/false values. A purchase needs an amount of zero or more and a three-letter currency
  (`INR` if you give none). An `orderId` with unsupported characters is left off and the purchase is still recorded. Every event has
  its own id, so a resend after a bad network is stored once, and the same event repeated within a second counts once.
- **One person, many phones:** call `setUserId` after sign-in and `resetUser()` on sign-out. Both first send what is waiting under the
  previous identity (they wait at most 5 seconds). User ids are 1 to 100 visible ASCII characters with no spaces; anything else is
  ignored. Without one, each install is its own anonymous person.
- **Deferred links and the paste notice:** on the first launch after install the SDK reads the clipboard once per try, looking for
  the `vlink:` token the link page copied. It asks `hasStrings` first, so a clipboard without text is never read. iOS may show its
  "pasted from" notice, and from iOS 16 a system question "Allow Paste" when the text was copied in another app (the SDK reads
  it away from the main thread, so your UI keeps running while the question is open). If the person taps "Don't Allow Paste", no
  token is sent and the service can still match by network fingerprint. It makes at most 3 tries and stops after the first success.
- **Adding the SDK to an app that is already installed:** the first-launch check also runs once for people who update. Pass
  `matchDeferred: false` in that release and turn it on in the next one. `first_open` cannot tell an existing install from a new
  one: anyone who updates to the first release that contains the SDK (or from an older SDK version that had not yet reported it)
  sends `first_open` and `session_start` once, so the dashboard's new-installs figure rises for that release.
- **Errors:** every network step has a time limit (`requestTimeout`, 10 seconds). Explicit calls such as `createLink` throw
  `VelaLinksError`; background work never throws and never stops your app starting. `baseUrl` must be `https://` (plain `http://`
  only for `localhost`), and redirects are never followed.
- **Threads:** all calls are safe from any thread. Tracking is held in memory behind a short lock and saved on a background queue.
  `onLink` closures run on the main thread.
- **Background time:** when the app moves to the background the SDK asks iOS for extra running time (`beginBackgroundTask`, ended on
  every path) so the final send is not cut off. If iOS still runs out of patience, the batch is kept and sent next time. The package
  also compiles into app extensions; there it asks for no extra time. An extension has its own bundle id and its own
  `UserDefaults`, so it must pass `appId:` (the parent app's bundle id) to `configure`, and, if it should share the install id and
  state with the app, a shared `userDefaults:` suite (for example `UserDefaults(suiteName: "group.your.app")`).

## Privacy: what the SDK sends and stores
**Sent to the Vela Links service, over https**
- Always: your SDK key, your app's bundle id, the link code that opened the app, and whether it came from a link or a QR code. When
  you create a link: the route, params and title (and the other fields) you give it.
- With in-app events: the event name, the time, your properties, screen names, purchase amounts, currency and order ids, the app
  version, the platform (`ios`), a random install id made on the phone, the user id if you call `setUserId` (the service stores only a
  one-way hash), and the links that brought the install. The service adds a country from the request and keeps no IP address. It
  replaces values that look like an email address or a long phone number, but it cannot recognise names or addresses in free text, so
  do not send personal data.
- With people data, only if your app calls it: the facts you give (plain labels, numbers, yes/no), the phone's language and optional time zone and
  quiet hours, the push token, the person's consent answers, and the signed identity token your server made. With in-app messages: the install
  id, the screen or event name, the language and the message id and what the person did with it (shown, tapped, closed, video progress).
- First launch after install: the clipboard is read once per try, only to look for a Vela Links token (`vlink:` and letters or digits).
  Any other clipboard text is ignored and never sent. If there is no token, the service can still match the install to a recent tap
  using a one-way hash of the network address (it never stores the address itself). The token is removed from the clipboard once
  used, but only if nothing was copied since.

**Stored on the phone** (`UserDefaults`, keys starting `vela_links.`): the random install id (made and stored on the first launch,
before any consent and even when tracking is off, but sent only once tracking is on); the events not yet sent (names and
properties, in plain text, for up to 7 days); the links that brought the install and last opened the app; your user id if you set
one; the names of once-only events already sent; whether first-open was reported and when the app was last active; whether tracking
is switched off; whether the first-launch check finished; and, if you use people data, the identity token, the facts, push token and
consent answers waiting to be delivered, what was delivered, and the answers you recorded. iCloud backups can restore these onto a new phone, which would give
two phones one install id. If that matters to you, pass your own `userDefaults:` suite and keep it out of backups.

**Not used:** no advertising id (IDFA), no hardware device id, no location, no third-party libraries, no method swizzling.

**Privacy manifest.** The package ships `PrivacyInfo.xcprivacy`: no tracking and no tracking domains; the `UserDefaults` required-reason
API (`CA92.1`); and the data types the SDK can send, all linked to the person and used for analytics only: device id (the random
install id and, if you pass one, the push token), user id, product interaction, purchase history, other usage data and other data (the facts you give), used for analytics and for the developer's own messages. Xcode merges it into your app's privacy report.

Please describe this in your app's privacy policy, ask for consent where your law requires it, and use it to fill in the App Store
privacy details.

## Support and security
Questions: info@velaapps.in. To report a security problem privately, see [SECURITY.md](SECURITY.md).

## License
MIT. See [LICENSE](LICENSE).
