import Foundation

/// A property value that can be sent: text, a number, true/false or null.
enum JSONScalar: Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    /// Converts a value an app handed over. Anything that is not text, a finite number, a boolean or null gives `nil`.
    static func from(_ any: Any) -> JSONScalar? {
        if any is NSNull { return .null }
        let mirror = Mirror(reflecting: any)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return .null }
            return from(wrapped)
        }
        if let text = any as? String { return .string(String(text.prefix(100))) }
        if let number = any as? NSNumber {
            #if canImport(Darwin)
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            #endif
            #if canImport(Darwin)
            let isFloat = CFNumberIsFloatType(number)
            #else
            let isFloat = String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f"
            #endif
            if isFloat {
                let d = number.doubleValue
                return d.isFinite ? .double(d) : nil
            }
            return .int(number.int64Value)
        }
        return nil
    }

    var json: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

/// One thing that happened in the app, waiting to be sent. Immutable, and compared by identity when it leaves the queue.
final class TrackedEvent: @unchecked Sendable {
    let name: String
    let at: Date
    let screen: String?
    let properties: [String: JSONScalar]?
    let value: Double?
    let currency: String?
    let id: String?
    let once: Bool
    let orderId: String?

    private init(name: String, at: Date, screen: String?, properties: [String: JSONScalar]?, value: Double?,
                 currency: String?, id: String?, once: Bool, orderId: String?) {
        self.name = name
        self.at = at
        self.screen = screen
        self.properties = properties
        self.value = value
        self.currency = currency
        self.id = id
        self.once = once
        self.orderId = orderId
    }

    /// Checks the values and returns the event, or `nil` if they are not acceptable: a bad name, a negative amount, a currency
    /// that is not three letters. Tracking never throws into the app, so an unusable event is simply dropped.
    static func tryCreate(_ name: String, at: Date, screen: String? = nil, properties: [String: Any]? = nil,
                          value: Double? = nil, currency: String? = nil, id: String? = nil, once: Bool = false,
                          orderId: String? = nil) -> TrackedEvent? {
        guard Check.eventName(name) else { return nil }
        if let value = value, !value.isFinite || value < 0 { return nil }
        if let currency = currency, !Check.currency(currency) { return nil }
        // an order id the service would not accept is left off: the purchase itself is kept
        let order = orderId.flatMap { Check.orderId($0) ? $0 : nil }
        let shortScreen = screen.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }
        return TrackedEvent(name: name, at: at, screen: shortScreen, properties: cleanProperties(properties),
                            value: value, currency: currency?.uppercased(),
                            id: id.flatMap { Check.eventId($0) ? $0 : nil }, once: once, orderId: order)
    }

    /// At most 10 properties with simple names and short text, numbers or true/false values. Anything else is left out.
    private static func cleanProperties(_ raw: [String: Any]?) -> [String: JSONScalar]? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        var out: [String: JSONScalar] = [:]
        // a stable order, so the same input always keeps the same 10
        for key in raw.keys.sorted() {
            if out.count >= 10 { break }
            guard Check.propertyKey(key), let value = raw[key], let scalar = JSONScalar.from(value) else { continue }
            out[key] = scalar
        }
        return out.isEmpty ? nil : out
    }

    /// The form sent to the service.
    func toJSON() -> [String: Any] {
        var out: [String: Any] = ["name": name, "ts": Int64((at.timeIntervalSince1970 * 1000).rounded(.down))]
        if let screen = screen { out["screen"] = screen }
        if let properties = properties { out["props"] = properties.mapValues { $0.json } }
        if let value = value { out["value"] = value }
        if let currency = currency { out["currency"] = currency }
        if let id = id { out["eid"] = id }
        if once { out["once"] = true }
        if let orderId = orderId { out["order_id"] = orderId }
        return out
    }

    /// Reads an event saved on the phone. Returns `nil` if it is damaged.
    static func fromJSON(_ json: Any) -> TrackedEvent? {
        guard let dict = json as? [String: Any], let name = dict["name"] as? String,
              let ts = (dict["ts"] as? NSNumber)?.int64Value else { return nil }
        return tryCreate(name, at: Date(timeIntervalSince1970: Double(ts) / 1000),
                         screen: dict["screen"] as? String,
                         properties: dict["props"] as? [String: Any],
                         value: (dict["value"] as? NSNumber)?.doubleValue,
                         currency: dict["currency"] as? String,
                         id: dict["eid"] as? String,
                         once: (dict["once"] as? NSNumber)?.boolValue == true,
                         orderId: dict["order_id"] as? String)
    }
}
