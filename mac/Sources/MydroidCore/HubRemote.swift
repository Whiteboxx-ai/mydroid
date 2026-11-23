import Foundation

// Hub side of PROTOCOL.md 10 (Remote), 11 (quick actions and Mac status).

extension Hub {
    // MARK: remote.state

    /// Tells the phone whether the Mac may post input and what is presenting. Remembered, and sent on connect and when it changes.
    public func setRemoteState(accessibility: Bool, presenting: String?) {
        queue.async {
            let r = RemoteStatus(accessibility: accessibility, presenting: presenting)
            let first = !self.remoteReported
            self.remoteReported = true
            guard r != self.state.remote || first else { return }
            self.state.remote = r
            self.sendRemoteState()
            self.publish()
        }
    }

    func sendRemoteState() {
        let r = state.remote
        guard remoteReported, active != nil, r != remoteSent else { return }
        remoteSent = r
        send(Message("remote.state", r.wireFields))
    }

    // MARK: mac.status

    /// The Mac's status for the phone. Sent on connect and only when it differs from what the phone last got.
    public func setMacStatus(_ s: MacStatus) {
        queue.async {
            guard s != self.state.macStatus else { return }
            self.state.macStatus = s
            self.sendMacStatus()
            self.publish()
        }
    }

    func sendMacStatus() {
        guard let s = state.macStatus, active != nil, s != macStatusSent else { return }
        macStatusSent = s
        send(Message("mac.status", s.wireFields))
    }

    // MARK: mac.action, mac.shortcuts.get

    /// Carries what a late answer needs across queues.
    private struct Reply: @unchecked Sendable {
        let hub: Hub
        let peer: Peer
        let type: String
        let req: WireID?

        func send(_ fields: [String: Any]) {
            hub.queue.async {
                guard self.peer === self.hub.active else { return }
                var f = fields
                if let req = self.req { f["req"] = req.json }
                self.peer.send(Message(self.type, f))
            }
        }
    }

    func handleMacAction(_ m: Message, from peer: Peer) {
        let reply = Reply(hub: self, peer: peer, type: "mac.result", req: WireID(any: m.fields["req"]))
        @Sendable func answer(_ r: MacActionResult) {
            var f: [String: Any] = ["ok": r.ok]
            if let e = r.error { f["error"] = e }
            if let n = r.note { f["note"] = n }
            reply.send(f)
        }
        guard let action = MacAction(message: m) else { answer(.failure("Unknown action")); return }
        guard let handler = macActions else { answer(.failure("unsupported")); return }
        handler.perform(action) { answer($0) }
    }

    func handleShortcutsGet(_ m: Message, from peer: Peer) {
        let reply = Reply(hub: self, peer: peer, type: "mac.shortcuts", req: WireID(any: m.fields["req"]))
        guard let handler = macActions else { reply.send(["error": "unsupported", "items": [String]()]); return }
        handler.listShortcuts { result in
            switch result {
            case let .success(items): reply.send(["items": items])
            case let .failure(e): reply.send(["error": e.message, "items": [String]()])
            }
        }
    }
}
