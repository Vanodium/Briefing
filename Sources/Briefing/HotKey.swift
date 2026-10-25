import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon: needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, userData, &handlerRef)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D524E47), id: 1)  // 'MRNG'
        let reg = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else {
            Log.write("hotkey not registered: \(reg)")
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Owns the one global shortcut (Settings → Shortcuts → Show or hide Briefing).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: () -> Void = {}
    private var hotKey: HotKey?
    private var registered: KeyCombo?
    private var suspended = false

    /// Registers the shortcut saved in Settings. False if macOS or another app already holds it.
    @discardableResult
    func reload() -> Bool {
        guard !suspended else { return true }
        return register(SettingsStore.shared.settings.combos(.toggle).first)
    }

    /// Tries a combination without saving it. False if it cannot be registered.
    func register(_ combo: KeyCombo?) -> Bool {
        if combo == registered, hotKey != nil { return true }
        hotKey = nil          // unregister the old one first, or the same keys would clash with themselves
        registered = nil
        guard let combo else { return true }
        hotKey = HotKey(keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.action() }
        }
        if hotKey != nil {
            registered = combo
            Log.write("global shortcut: \(combo.display)")
            return true
        }
        return false
    }

    /// While a shortcut is being recorded in Settings, the current one must not fire.
    func suspend() {
        suspended = true
        hotKey = nil
        registered = nil
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        reload()
    }
}
