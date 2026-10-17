import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)
@available(iOS 13.0, macOS 10.15, *)
private struct VelaScreenModifier: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.onAppear { VelaLinks.shared.trackScreen(name) }
    }
}

@available(iOS 13.0, macOS 10.15, *)
extension View {
    /// Reports this view as a screen when it appears: `ContentView().velaScreen("Home")`. The same screen twice in a row is
    /// reported once. Use it on screens only, not on dialogs or sheets.
    public func velaScreen(_ name: String) -> some View {
        modifier(VelaScreenModifier(name: name))
    }
}
#endif

#if canImport(UIKit) && !os(watchOS)
extension UIViewController {
    /// Reports this view controller as a screen. Call it from `viewDidAppear(_:)`; there is no method swizzling.
    /// The name defaults to the class name. Do not call it for alerts and sheets.
    public func velaTrackScreen(_ name: String? = nil) {
        VelaLinks.shared.trackScreen(name ?? String(describing: type(of: self)))
    }
}

/// A view controller that reports itself as a screen each time it appears. Subclass it, and set `velaScreenName` to override
/// the class name.
open class VelaScreenViewController: UIViewController {
    /// The screen name; the class name when `nil`.
    open var velaScreenName: String? { nil }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        velaTrackScreen(velaScreenName)
    }
}
#endif
