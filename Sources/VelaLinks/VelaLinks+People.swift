import Foundation

extension VelaLinks {
    /// Gives the signed proof of who the person is: the token your own server makes when someone signs in (see the guide "Identity
    /// token"). Your server signs it with the identity secret from the dashboard; the app never holds that secret. Without the
    /// token nothing about the person (properties, push token, consent) is sent, and events from a signed-in person count as
    /// anonymous when the app has strict identity on. Pass `nil` when they sign out (``resetUser()`` does this too). A token with
    /// spaces, or over 1000 characters, is ignored. It is kept on the phone and sent with events and with the calls below.
    public func setIdentityToken(_ token: String?) async {
        await runAsync { await $0.tracker.setIdentityToken(token) }
    }

    /// Tells Vela Links plain facts about the signed-in person so campaigns can use them, for example
    /// `setUserProperties(["lang": "te", "orders": 3, "uses_business": true])`.
    ///
    /// Only plain labels, numbers and yes/no are accepted: names that sound personal (phone, email, name, address, religion,
    /// health ...) and values that look like a phone number or an email are dropped before anything is sent. Up to 20 properties;
    /// `nil` removes one. Changes are sent together a little later, and only what changed. `locale` (such as `te` or `hi-IN`)
    /// defaults to the phone's language; `timezone` is an IANA name such as `Asia/Kolkata`; `quietStart` and `quietEnd` are hours
    /// (0 to 23) when the person does not want offers. Needs ``setIdentityToken(_:)``; until then the facts are kept on the phone.
    /// Never throws.
    public func setUserProperties(_ properties: [String: Any?], locale: String? = nil, timezone: String? = nil,
                                  quietStart: Int? = nil, quietEnd: Int? = nil) {
        let props = HandedOver(properties)
        runNow {
            $0.people.setProperties(props.value, locale: locale, timezone: timezone, quietStart: quietStart, quietEnd: quietEnd)
        }
    }

    /// Gives the phone's push token so you can send this person notifications later. `provider` is `"fcm"` (what Firebase gives
    /// you, the default) or `"apns"` (the hex of the token iOS gives you; see ``registerPushToken(apnsDeviceToken:)``). It is
    /// stored encrypted and is only ever used for a person who agreed to notifications (``setConsent(_:granted:policyVersion:purpose:source:)``).
    /// Call it again whenever it changes; a token already delivered is not sent twice. Needs ``setIdentityToken(_:)``. The token
    /// is collected only if your app calls this.
    public func registerPushToken(_ token: String, provider: String = "fcm") {
        runNow { $0.people.setPushToken(token, provider: provider) }
    }

    /// Gives the raw token iOS hands to `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` (provider `"apns"`).
    public func registerPushToken(apnsDeviceToken: Data) {
        registerPushToken(apnsDeviceToken.map { String(format: "%02x", $0) }.joined(), provider: "apns")
    }

    /// Records what the person agreed to or withdrew. `channel` is `push`, `whatsapp`, `sms`, `email` or `inapp` (offers shown
    /// inside the app); `purpose` is `marketing` (offers, nudges) or `service` (what they asked for); `policyVersion` names the
    /// privacy notice they saw, such as `2026-10`; `source` is `app_prompt` or `settings_toggle`. Withdrawing takes effect at once.
    /// Call it whenever the person answers or changes a setting; it is kept until delivered. Returns `false` when the input is not
    /// valid. Needs ``setIdentityToken(_:)``. Before `configure` has finished the answer is kept in order, and ``consentOf(_:purpose:)``
    /// knows it once `configure` is done.
    @discardableResult
    public func setConsent(_ channel: String, granted: Bool, policyVersion: String, purpose: String = "marketing",
                           source: String = "app_prompt") -> Bool {
        guard ConsentCheck.valid(channel: channel, purpose: purpose, policyVersion: policyVersion, source: source) else {
            return false
        }
        runNow {
            _ = $0.people.setConsent(channel, granted: granted, policyVersion: policyVersion, purpose: purpose, source: source)
        }
        return true
    }

    /// What the person last chose on this phone for `channel` (`true`, `false`, or `nil` if they were never asked).
    public func consentOf(_ channel: String, purpose: String = "marketing") -> Bool? {
        currentEngine()?.people.consentOf(channel, purpose: purpose)
    }

    /// This install's random id. Show it in a debug screen to register the phone for testing messages in the dashboard.
    public var installId: String? { currentEngine()?.tracker.installId }
}
