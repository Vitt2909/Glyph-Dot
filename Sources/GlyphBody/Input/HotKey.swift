#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox

/// Atalho global sem pedir Acessibilidade (Carbon `RegisterEventHotKey`).
///
/// - `⌃⌥Espaço`: chamar o Glyph.
/// - `⌃⌥⌘.`: freio (M3): pausa geral.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private var nextID: UInt32 = 1

    /// Registra um atalho. `keyCode` é um `kVK_*`; `modifiers` usa `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    @discardableResult
    public func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C5948), id: id) // 'GLYH'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    public func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            // O Carbon entrega na thread principal.
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
#endif
