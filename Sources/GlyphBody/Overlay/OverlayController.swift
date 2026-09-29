#if canImport(AppKit)
import AppKit
import GlyphCore

/// Um painel + uma `GlyphView` por tela.
@MainActor
public final class OverlayController {
    public let screen: NSScreen
    public let panel: OverlayPanel
    public let view: GlyphView
    private let toggler = HitTestToggler()

    public init(screen: NSScreen) {
        self.screen = screen
        panel = OverlayPanel(screen: screen)
        view = GlyphView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.screenOrigin = screen.frame.origin
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFrontRegardless()
    }

    /// Desenha o quadro se o Glyph estiver nesta tela; senão esconde.
    public func show(_ drawing: GlyphDrawing?) {
        show(drawing.map { [$0] } ?? [])
    }

    /// Vários Glyphs; o primeiro é o principal (o único que recebe mouse).
    public func show(_ drawings: [GlyphDrawing]) {
        let here = drawings.filter { screen.frame.intersects($0.bounds.cgRect) }
        view.show(here)
        if let main = drawings.first, screen.frame.intersects(main.bounds.cgRect) {
            toggler.update(panel: panel, hitbox: main.bounds.cgRect)
        } else {
            panel.ignoresMouseEvents = true
        }
    }

    public func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

extension Rect {
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
    }
}

extension Vec2 {
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    public init(_ p: CGPoint) { self.init(p.x, p.y) }
}
#endif
