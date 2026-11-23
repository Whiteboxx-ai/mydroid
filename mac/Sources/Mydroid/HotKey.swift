import AppKit
import Carbon.HIToolbox

/// Registers system-wide shortcuts with Carbon. One handler dispatches by hot key id. None of these needs a permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Registers (or replaces) the shortcut with this id. Returns false when the system refuses it (already taken).
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x4D59_4452), id: id)   // 'MYDR'
        let status = RegisterEventHotKey(keyCode, modifiers, hkid, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions[id] = nil
    }
}

/// A system-wide shortcut (Control-Option-M) that opens the Mydroid window from any app.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let description = "\u{2303}\u{2325}M"
    private var registered = false

    func register(_ action: @escaping () -> Void) {
        guard !registered else { return }
        registered = HotKeyCenter.shared.register(id: 1, keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), action: action)
    }
}
