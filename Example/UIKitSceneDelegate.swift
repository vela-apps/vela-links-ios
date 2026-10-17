// The same wiring for a UIKit app that uses a SceneDelegate.
import UIKit
import VelaLinks

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var observation: VelaLinkObservation?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        observation = VelaLinks.shared.onLink { link in
            guard link.route == "/product" else { return }
            // push your product screen using link.params
        }
        options.userActivities.forEach { VelaLinks.shared.handle(userActivity: $0) }
        options.urlContexts.forEach { VelaLinks.shared.handle(url: $0.url) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        VelaLinks.shared.handle(userActivity: userActivity)
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.forEach { VelaLinks.shared.handle(url: $0.url) }
    }
}

final class ProductViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        velaTrackScreen("Product")
    }
}
