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

    /// The phone asked, so say what is true now even if it hasn't changed: that is how it knows the answer is fresh.
    public func resendRemoteState() {
        queue.async {
            self.remoteSent = nil
            self.sendRemoteState()
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

    // MARK: PROTOCOL.md 16: apps, opening files, presenting, Mac media

    func handleRemoteV2(_ m: Message, from peer: Peer) {
        let reply = Reply(hub: self, peer: peer, type: "mac.result", req: WireID(any: m.fields["req"]))
        @Sendable func answer(_ r: MacActionResult) {
            var f: [String: Any] = ["ok": r.ok]
            if let e = r.error { f["error"] = e }
            reply.send(f)
        }
        guard let handler = macRemote else {
            switch m.type {
            case "mac.apps.get": Reply(hub: self, peer: peer, type: "mac.apps", req: WireID(any: m.fields["req"])).send(["running": [Any](), "apps": [Any]()])
            case "present.watch", "mac.media.watch", "mac.media.cmd": break
            default: answer(.failure("unsupported"))
            }
            return
        }
        switch m.type {
        case "mac.apps.get":
            let apps = Reply(hub: self, peer: peer, type: "mac.apps", req: WireID(any: m.fields["req"]))
            handler.apps { l in
                apps.send([
                    "running": l.running.prefix(16).map { a -> [String: Any] in
                        var d: [String: Any] = ["id": a.id, "name": a.name]
                        if let i = a.icon { d["icon"] = i.base64EncodedString() }
                        return d
                    },
                    "apps": l.installed.prefix(300).map { ["id": $0.id, "name": $0.name] },
                ])
            }
        case "mac.launch":
            guard let id = m.string("id"), !id.isEmpty, id.count < 200 else { return answer(.failure("bad request")) }
            handler.launch(id) { answer($0) }
        case "mac.open", "present.start":
            do {
                let url = try fileShare.resolveForOpen(root: m.string("root"), path: m.string("path"), regularFileOnly: m.type == "present.start")
                if m.type == "mac.open" { handler.open(url) { answer($0) } }
                else { handler.present(url, play: m.bool("play") ?? true) { answer($0) } }
            } catch let e as FileShareError {
                answer(.failure(e == .off ? "File sharing is off on your Mac" : "That file isn't on your Mac any more"))
            } catch { answer(.failure("denied")) }
        case "present.watch":
            let on = m.bool("on") ?? false
            presentWatching = on; presentSent = nil
            handler.setPresentWatching(on)
        case "mac.media.watch":
            let on = m.bool("on") ?? false
            mediaWatching = on; mediaSent = nil
            handler.setMediaWatching(on)
        case "mac.media.cmd":
            if let c = MacMediaCommand(message: m) { handler.mediaCommand(c) }
        default: break
        }
    }

    /// The session ended: nobody is looking at the slides or the song any more.
    func stopRemoteV2Watching() {
        if presentWatching { presentWatching = false; macRemote?.setPresentWatching(false) }
        if mediaWatching { mediaWatching = false; macRemote?.setMediaWatching(false) }
        presentSent = nil; mediaSent = nil
    }

    /// Called by the presenting service. Sent only while the phone is watching, and only when it changed.
    public func setPresentState(_ s: PresentState) {
        queue.async {
            guard self.presentWatching, self.active != nil, s != self.presentSent else { return }
            self.presentSent = s
            self.send(Message("present.state", s.wireFields))
        }
    }

    /// Called by the media service, which already decided that this is worth sending.
    public func setMacMedia(_ m: MacMedia) {
        queue.async {
            guard self.mediaWatching, self.active != nil else { return }
            self.mediaSent = m
            self.send(Message("mac.media", m.wireFields))
        }
    }
}
