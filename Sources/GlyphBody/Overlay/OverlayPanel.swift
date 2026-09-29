#if canImport(AppKit)
import AppKit

/// Painel transparente, sem foco, que cobre uma tela inteira.
///
/// O clique atravessa tudo, exceto a hitbox do Glyph: quem alterna
/// `ignoresMouseEvents` é o `HitTestToggler`, a cada quadro.
@MainActor
public final class OverlayPanel: NSPanel {
    public init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        setFrame(screen.frame, display: false)
    }

    // Nunca rouba foco do app do usuário.
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// Liga o mouse no painel só quando o cursor está sobre o Glyph.
@MainActor
public struct HitTestToggler {
    public init() {}

    /// `hitbox` em coordenadas globais do AppKit.
    public func update(panel: NSPanel, hitbox: CGRect, mouse: CGPoint = NSEvent.mouseLocation) {
        let inside = hitbox.insetBy(dx: -4, dy: -4).contains(mouse)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }
}
#endif
