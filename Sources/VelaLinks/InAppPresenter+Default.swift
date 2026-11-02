import Foundation

/// The presenter an app gets: the UIKit one on iOS, none where there is nothing to draw on (the SDK then never asks for messages).
enum DefaultInAppPresenter {
    static func make() -> InAppPresenter? {
        #if canImport(UIKit) && !os(watchOS)
        return UIKitInAppPresenter()
        #else
        return nil
        #endif
    }
}
