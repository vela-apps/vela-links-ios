#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Reaches the running application and its scenes.
///
/// `UIApplication.shared` is marked unavailable to app extensions, and a package that names it does not compile into an extension
/// target. So the application object is reached by name at run time (as `UIKitBackgroundTaskRunner` does): it is the same object in
/// an app, and in an extension there is none, so no message is drawn there.
enum UIKitApplication {
    /// The running application, or `nil` in an app extension.
    static func shared() -> NSObject? {
        guard !Bundle.main.bundlePath.hasSuffix(".appex"),
              let type = NSClassFromString("UIApplication") as? NSObject.Type,
              let shared = type.perform(NSSelectorFromString("sharedApplication")) else { return nil }
        return shared.takeUnretainedValue() as? NSObject
    }

    /// Every window scene the app has.
    @MainActor
    static func windowScenes() -> [UIWindowScene] {
        guard let scenes = shared()?.value(forKey: "connectedScenes") as? Set<UIScene> else { return [] }
        return scenes.compactMap { $0 as? UIWindowScene }
    }

    /// The scene the person is using right now: the one that is active in the foreground (the one with the key window if two
    /// are), or `nil` when the app is in the background.
    @MainActor
    static func foregroundScene() -> UIWindowScene? {
        let active = windowScenes().filter { $0.activationState == .foregroundActive }
        return active.first { scene in scene.windows.contains { $0.isKeyWindow } } ?? active.first
    }
}

extension UIColor {
    convenience init(_ color: InAppColor) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
#endif
