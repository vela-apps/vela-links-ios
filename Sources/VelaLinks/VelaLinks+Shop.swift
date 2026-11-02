import Foundation

/// The standard events campaigns understand, for example "added to cart, did not order". Each one is an ordinary event with plain
/// properties (`items`, `cart_value`, `store`, `category`): nothing here is personal.
extension VelaLinks {
    /// Records that something was added to the cart. `items` is how many, `cartValue` the new total of the cart; `store` and
    /// `category` are short labels.
    public func trackAddToCart(items: Int = 1, cartValue: Double? = nil, store: String? = nil, category: String? = nil) {
        track("add_to_cart", properties: VelaLinks.shopProperties(items, cartValue, store, category))
    }

    /// Records that something was taken out of the cart.
    public func trackRemoveFromCart(items: Int = 1, store: String? = nil) {
        track("remove_from_cart", properties: VelaLinks.shopProperties(items, nil, store, nil))
    }

    /// Records that the person started to check out.
    public func trackBeginCheckout(items: Int = 1, cartValue: Double? = nil, store: String? = nil) {
        track("begin_checkout", properties: VelaLinks.shopProperties(items, cartValue, store, nil))
    }

    /// Records that the person looked at an item. `category` and `store` are short labels, never the item's name.
    public func trackViewItem(category: String? = nil, store: String? = nil) {
        track("view_item", properties: VelaLinks.shopProperties(nil, nil, store, category))
    }

    /// Records that the person signed up, with the `method` they used (`phone`, `google` ...).
    public func trackSignup(method: String? = nil) {
        track("signup", properties: method.map { ["method": $0] })
    }

    /// Records that the person signed in.
    public func trackLogin(method: String? = nil) {
        track("login", properties: method.map { ["method": $0] })
    }

    static func shopProperties(_ items: Int?, _ cartValue: Double?, _ store: String?, _ category: String?) -> [String: Any] {
        var out: [String: Any] = [:]
        if let items = items { out["items"] = items }
        if let cartValue = cartValue { out["cart_value"] = cartValue }
        if let store = store { out["store"] = store }
        if let category = category { out["category"] = category }
        return out
    }
}
