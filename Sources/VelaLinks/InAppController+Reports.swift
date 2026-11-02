import Foundation

extension InAppController {
    /// The function that tells the service what happens to one message (`shown`, `clicked`, `dismissed`, video progress ...).
    /// Each report is sent in the background; one that cannot be sent is kept (up to 50) and sent again by `retryReports()`.
    func reporter(for message: InAppMessage) -> @Sendable (String, Int?) -> Void {
        let id = message.id
        return { [weak self] action, button in
            guard let self = self else { return }
            var body: [String: Any] = ["sid": self.sources.sessionId(), "message_id": id, "action": action]
            if let iid = self.sources.installId() { body["iid"] = iid }
            if let proof = self.sources.identity() { body["identity_token"] = proof }
            if let button = button { body["button"] = button }
            self.enqueue(HandedOver(body))
        }
    }

    /// Reports go out one after the other in the order they were made, so `shown` always reaches the service before `clicked`.
    private func enqueue(_ body: HandedOver<[String: Any]>) {
        lock.sync {
            let before = reportChain
            reportChain = Task {
                await before?.value
                await self.send(body.value)
            }
        }
    }

    private func send(_ body: [String: Any]) async {
        let result = await api.post("/v1/inapp/events", body)
        guard result == .retry || result == .needsIdentity else { return }
        let handed = HandedOver(body)
        lock.sync {
            if unsent.count >= InAppController.maxUnsent { unsent.removeFirst() }
            unsent.append(handed)
        }
    }

    /// Waits until every report made so far has been tried (used by tests).
    func finishReports() async {
        await lock.sync { reportChain }?.value
    }

    /// Sends reports that could not be sent before (called when the app comes back).
    func retryReports() async {
        let waiting: [HandedOver<[String: Any]>] = lock.sync {
            let list = unsent
            unsent = []
            return list
        }
        for item in waiting {
            var body = item.value
            body["identity_token"] = sources.identity()
            enqueue(HandedOver(body))
        }
        await finishReports()
    }
}
