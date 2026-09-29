#if canImport(AppKit)
import AppKit

/// Acompanha o cursor no sistema inteiro.
///
/// Monitores globais de `.mouseMoved` não exigem permissão (só eventos de
/// teclado exigem). O monitor local cobre o mouse sobre o próprio Glyph.
@MainActor
public final class CursorMonitor {
    private var global: Any?
    private var local: Any?
    public var onMove: ((CGPoint) -> Void)?

    public init() {}

    public func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
            return event
        }
    }

    public func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }
}
#endif
