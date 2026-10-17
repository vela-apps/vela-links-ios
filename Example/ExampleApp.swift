// A small SwiftUI app showing the whole flow. Copy the parts you need; this folder is not part of the package build.
import SwiftUI
import VelaLinks

@main
struct ExampleApp: App {
    @State private var route: String?

    init() {
        Task {
            do {
                try await VelaLinks.configure(
                    apiKey: "vl_...",
                    baseUrl: "https://api.links.velaapps.in",
                    slug: "your-app-slug"
                )
            } catch {
                print("Vela Links could not start: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(route: $route)
                .onOpenURL { VelaLinks.shared.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { VelaLinks.shared.handle(userActivity: $0) }
                .task {
                    // a link that arrived before we listened, then every later one
                    if let pending = VelaLinks.shared.consumePendingLink() { open(pending) }
                    for await link in VelaLinks.shared.links { open(link) }
                }
        }
    }

    private func open(_ link: VelaLink) {
        guard ["/invite", "/product"].contains(link.route) else { return } // only screens you allow
        route = link.route
    }
}

struct ContentView: View {
    @Binding var route: String?
    @State private var shareUrl: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Opened: \(route ?? "nothing")")
            Button("Create invite link") {
                Task {
                    shareUrl = try? await VelaLinks.shared.createLink(route: "/invite", params: ["id": "42"])
                    VelaLinks.shared.track("share", properties: ["channel": "link"])
                }
            }
            if let shareUrl = shareUrl { Text(shareUrl).font(.footnote) }
            Button("Buy") { VelaLinks.shared.trackPurchase(499, orderId: "ORD-1001") }
        }
        .velaScreen("Home")
    }
}
