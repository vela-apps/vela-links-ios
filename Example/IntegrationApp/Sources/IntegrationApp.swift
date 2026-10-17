// A minimal test app for driving the SDK from the command line. The command router is for testing only; it is not part of the SDK.
import SwiftUI
import VelaLinks
import os

enum Log {
    static let logger = Logger(subsystem: "in.velaapps.links.integration", category: "e2e")
    static func write(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("e2e.log")
        let text = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Reads a setting from launch arguments (`-apiKey x`) first, then Info.plist.
func setting(_ argument: String, _ plistKey: String) -> String? {
    if let value = UserDefaults.standard.string(forKey: argument), !value.isEmpty { return value }
    return Bundle.main.object(forInfoDictionaryKey: plistKey) as? String
}

/// `velademo://cmd?do=track&name=signup&once=1` and friends. Debug only.
func runCommand(_ url: URL) {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
    func arg(_ n: String) -> String? { items.first { $0.name == n }?.value }
    let sdk = VelaLinks.shared
    Task {
        Log.write("CMD \(url.absoluteString)")
        switch arg("do") ?? "" {
        case "track":
            var props: [String: Any] = [:]
            for item in items where item.name.hasPrefix("p_") { props[String(item.name.dropFirst(2))] = item.value ?? "" }
            sdk.track(arg("name") ?? "", properties: props.isEmpty ? nil : props, once: arg("once") == "1")
        case "purchase":
            sdk.trackPurchase(Double(arg("amount") ?? "0") ?? 0, currency: arg("currency") ?? "INR", orderId: arg("order"))
        case "screen": sdk.trackScreen(arg("name") ?? "")
        case "uid": await sdk.setUserId(arg("id"))
        case "reset": await sdk.resetUser()
        case "enable": await sdk.setTrackingEnabled(arg("on") != "0")
        case "flush": await sdk.flush()
        case "offtest": // queue an event, switch tracking off straight away, try to track and send: nothing may arrive
            sdk.track("pre_off_queued")
            await sdk.setTrackingEnabled(false)
            sdk.track("while_off")
            await sdk.flush()
        case "state": Log.write("STATE configured=\(sdk.isConfigured) trackingEnabled=\(sdk.trackingEnabled)")
        case "createlink":
            do {
                let made = try await sdk.createLink(route: arg("route") ?? "/invite", params: ["id": arg("id") ?? "1"],
                                                    title: arg("title"), campaign: arg("campaign"))
                Log.write("CREATED \(made)")
            } catch { Log.write("CREATE-FAILED \(error)") }
        default: Log.write("UNKNOWN-COMMAND")
        }
        Log.write("DONE \(arg("do") ?? "")")
    }
}

@main
struct IntegrationApp: App {
    @State private var lastLink = "none"

    init() {
        Log.write("LAUNCH")
        let args = UserDefaults.standard
        Task {
            do {
                try await VelaLinks.configure(
                    apiKey: setting("apiKey", "VLApiKey") ?? "",
                    baseUrl: setting("baseUrl", "VLBaseUrl") ?? "http://localhost:8000",
                    slug: setting("slug", "VLSlug"),
                    matchDeferred: args.string(forKey: "matchDeferred") != "0",
                    trackEvents: args.string(forKey: "trackEvents") != "0"
                )
                Log.write("CONFIGURED")
            } catch { Log.write("CONFIGURE-FAILED \(error)") }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(lastLink: $lastLink)
                .onOpenURL { url in
                    if url.host == "cmd" { runCommand(url) } else { Log.write("OPEN-URL handled=\(VelaLinks.shared.handle(url: url)) \(url.absoluteString)") }
                }
                .task {
                    if let pending = VelaLinks.shared.consumePendingLink() { show(pending) }
                    for await link in VelaLinks.shared.links { show(link) }
                }
        }
    }

    private func show(_ link: VelaLink) {
        lastLink = "\(link.route) \(link.code)"
        Log.write("ONLINK code=\(link.code) route=\(link.route) deferred=\(link.deferred) params=\(link.params)")
    }
}

struct ContentView: View {
    @Binding var lastLink: String
    var body: some View {
        VStack(spacing: 12) {
            Text("Last link: \(lastLink)")
            Button("Track signup") { VelaLinks.shared.track("signup") }
            Button("Purchase 499") { VelaLinks.shared.trackPurchase(499, orderId: "ORD-UI") }
            Button("Flush") { Task { await VelaLinks.shared.flush() } }
        }
        .velaScreen("Home")
    }
}
