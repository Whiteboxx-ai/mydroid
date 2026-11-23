import Foundation
import Network

/// Calls `onChange` (debounced) when the set of usable network paths changes.
public final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mydroid.netwatch")
    private var last: String?
    private var pending: DispatchWorkItem?

    public init() {}

    public func start(onChange: @escaping () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let sig = path.status == .satisfied
                ? path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",") + "|" + NetworkInfo.addresses(port: 0).joined(separator: ",")
                : "down"
            if self.last == nil { self.last = sig; return }
            guard sig != self.last else { return }
            self.last = sig
            self.pending?.cancel()
            let w = DispatchWorkItem { onChange() }
            self.pending = w
            self.queue.asyncAfter(deadline: .now() + 1.0, execute: w)
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}
