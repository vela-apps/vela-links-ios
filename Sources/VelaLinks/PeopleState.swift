import Foundation

/// The language, time zone and quiet hours waiting to be sent.
struct ProfileFields: Equatable {
    var locale: String?
    var timezone: String?
    var quietStart: Int?
    var quietEnd: Int?

    var isEmpty: Bool { locale == nil && timezone == nil && quietStart == nil && quietEnd == nil }

    /// The fields as the service names them.
    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let locale = locale { out["locale"] = locale }
        if let timezone = timezone { out["timezone"] = timezone }
        if let quietStart = quietStart { out["quiet_start"] = quietStart }
        if let quietEnd = quietEnd { out["quiet_end"] = quietEnd }
        return out
    }

    init(locale: String? = nil, timezone: String? = nil, quietStart: Int? = nil, quietEnd: Int? = nil) {
        self.locale = locale
        self.timezone = timezone
        self.quietStart = quietStart
        self.quietEnd = quietEnd
    }

    init(json: [String: Any]) {
        self.init(locale: json["locale"] as? String, timezone: json["timezone"] as? String,
                  quietStart: (json["quiet_start"] as? NSNumber)?.intValue,
                  quietEnd: (json["quiet_end"] as? NSNumber)?.intValue)
    }
}

/// A push token waiting to be delivered.
struct PendingPush: Equatable {
    let token: String
    let provider: String
}

/// One answer to "may we contact you here?", waiting to be delivered.
struct ConsentAnswer: Equatable {
    let channel: String
    let purpose: String
    let granted: Bool
    let policyVersion: String
    let source: String

    /// The body the service expects (the install id and identity token are added when it is sent).
    var json: [String: Any] {
        ["channel": channel, "purpose": purpose, "granted": granted, "policy_version": policyVersion, "source": source]
    }

    static func from(_ any: Any) -> ConsentAnswer? {
        guard let d = any as? [String: Any], let channel = d["channel"] as? String, let purpose = d["purpose"] as? String,
              let granted = (d["granted"] as? NSNumber)?.boolValue, let policy = d["policy_version"] as? String,
              let source = d["source"] as? String else { return nil }
        return ConsentAnswer(channel: channel, purpose: purpose, granted: granted, policyVersion: policy, source: source)
    }
}

/// Everything the people sync keeps on the phone until it has been delivered, plus what it last delivered.
struct PeopleState {
    var props: [String: JSONScalar] = [:]
    var profile = ProfileFields()
    var sent: [String: JSONScalar] = [:]
    var push: PendingPush?
    var sentPush: String?
    var consents: [ConsentAnswer] = []
    /// What the person last chose here, by `channel/purpose`: for the app's own settings screen.
    var answers: [String: Bool] = [:]

    // MARK: Saving and loading (JSON text in the storage)

    private static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ raw: String?) -> [String: Any] {
        raw.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
    }

    private static func scalars(_ raw: String?) -> [String: JSONScalar] {
        object(raw).compactMapValues { JSONScalar.from($0) }
    }

    /// Reads what was saved. Anything damaged is ignored.
    init(_ store: VelaLinksStorage) throws {
        props = PeopleState.scalars(try store.string(forKey: StorageKeys.pendingProps))
        profile = ProfileFields(json: PeopleState.object(try store.string(forKey: StorageKeys.pendingProfile)))
        sent = PeopleState.scalars(try store.string(forKey: StorageKeys.sentProps))
        sentPush = try store.string(forKey: StorageKeys.sentPush)
        let saved = PeopleState.object(try store.string(forKey: StorageKeys.pendingPush))
        if let token = saved["token"] as? String, let provider = saved["provider"] as? String {
            push = PendingPush(token: token, provider: provider)
        }
        if let raw = try store.string(forKey: StorageKeys.pendingConsent),
           let list = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any] {
            consents = list.compactMap(ConsentAnswer.from)
        }
        for (key, value) in PeopleState.object(try store.string(forKey: StorageKeys.consentState)) {
            if let flag = value as? NSNumber { answers[key] = flag.boolValue }
        }
    }

    init() {}

    /// Writes everything (the caller does it off the main thread).
    func save(to store: VelaLinksStorage) {
        try? store.setString(PeopleState.text(props.mapValues { $0.json }), forKey: StorageKeys.pendingProps)
        try? store.setString(PeopleState.text(profile.json), forKey: StorageKeys.pendingProfile)
        try? store.setString(PeopleState.text(sent.mapValues { $0.json }), forKey: StorageKeys.sentProps)
        let pending: [String: Any] = push.map { ["token": $0.token, "provider": $0.provider] } ?? [:]
        try? store.setString(PeopleState.text(pending), forKey: StorageKeys.pendingPush)
        try? store.setString(PeopleState.text(consents.map { $0.json }), forKey: StorageKeys.pendingConsent)
        try? store.setString(PeopleState.text(answers), forKey: StorageKeys.consentState)
        if let sentPush = sentPush {
            try? store.setString(sentPush, forKey: StorageKeys.sentPush)
        } else {
            try? store.remove(forKey: StorageKeys.sentPush)
        }
    }
}
