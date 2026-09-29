#if canImport(AppKit)
import AppKit
import QuartzCore
import GlyphCore

/// Desenha um `GlyphDrawing` no estilo adesivo com `CAShapeLayer`s.
///
/// A view cobre a tela inteira (é o content view do `OverlayPanel`). Ela não
/// decide nada: recebe o quadro pronto do Core e converte em caminhos.
@MainActor
public final class GlyphView: NSView {
    private let sticker = CALayer()
    private let paper = CAShapeLayer()     // contorno branco + preenchimento da cabeça
    private let ink = CAShapeLayer()       // traço preto
    private let dotPaper = CAShapeLayer()  // borda branca do Dot
    private let dotInk = CAShapeLayer()    // Dot
    private let bubble = BubbleLayer()

    public var style = StickerStyle.default {
        didSet { applyStyle() }
    }

    /// Origem da tela desta view em coordenadas globais.
    public var screenOrigin: CGPoint = .zero

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .clear
        for l in [paper, ink, dotPaper, dotInk] as [CAShapeLayer] {
            l.lineCap = .round
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "opacity": NSNull()]
            sticker.addSublayer(l)
        }
        sticker.actions = ["opacity": NSNull()]
        layer?.addSublayer(sticker)
        layer?.addSublayer(bubble.layer)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override public var isFlipped: Bool { false }

    private func applyStyle() {
        paper.strokeColor = NSColor.white.cgColor
        paper.fillColor = NSColor.white.cgColor
        paper.lineWidth = style.outlineStrokeWidth
        ink.strokeColor = NSColor.black.cgColor
        ink.fillColor = nil
        ink.lineWidth = style.inkWidth
        dotPaper.fillColor = NSColor.white.cgColor
        dotPaper.strokeColor = nil
        dotInk.fillColor = NSColor.black.cgColor
        dotInk.strokeColor = nil
        sticker.shadowColor = NSColor.black.cgColor
        sticker.shadowOpacity = Float(style.shadowOpacity)
        sticker.shadowRadius = style.shadowRadius
        sticker.shadowOffset = CGSize(width: style.shadowOffset.x, height: style.shadowOffset.y)
    }

    /// Mostra um quadro. `nil` esconde o Glyph (por exemplo, fora desta tela).
    public func show(_ drawing: GlyphDrawing?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let drawing else {
            sticker.isHidden = true
            bubble.isHidden = true
            return
        }
        sticker.isHidden = false
        sticker.opacity = Float(drawing.opacity)

        let shapes = StickerShapes.build(drawing, style: style)
        let strokePath = CGMutablePath()
        for s in shapes.strokes { addPolyline(s, to: strokePath) }
        let paperPath = CGMutablePath()
        paperPath.addPath(strokePath)
        for f in shapes.fills { addPolyline(f, to: paperPath, close: true) }

        let dots = CGMutablePath(), dotBorders = CGMutablePath()
        for d in shapes.discs where d.opacity > 0.01 {
            let c = local(d.center)
            dots.addEllipse(in: CGRect(x: c.x - d.radius, y: c.y - d.radius, width: 2 * d.radius, height: 2 * d.radius))
            let r = d.radius + style.outlineWidth * 0.6
            dotBorders.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        paper.path = paperPath
        ink.path = strokePath
        dotPaper.path = dotBorders
        dotInk.path = dots
        dotInk.opacity = Float(drawing.dot.opacity)

        if let text = drawing.bubble {
            bubble.isHidden = false
            let head = local(drawing.skeleton.headCenter + drawing.position)
            bubble.show(text: text, anchor: CGPoint(x: head.x, y: head.y + drawing.skeleton.headRadius + 10), in: bounds)
        } else {
            bubble.isHidden = true
        }
    }

    private func local(_ p: Vec2) -> CGPoint {
        CGPoint(x: p.x - screenOrigin.x, y: p.y - screenOrigin.y)
    }

    private func addPolyline(_ pts: [Vec2], to path: CGMutablePath, close: Bool = false) {
        guard let first = pts.first else { return }
        path.move(to: local(first))
        for p in pts.dropFirst() { path.addLine(to: local(p)) }
        if close { path.closeSubpath() }
    }

    // O painel só recebe mouse quando o cursor está sobre o Glyph,
    // então qualquer evento que chegue aqui é do Glyph.
    public var onMouseDown: ((NSEvent) -> Void)?
    public var onMouseDragged: ((NSEvent) -> Void)?
    public var onMouseUp: ((NSEvent) -> Void)?

    override public func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override public func rightMouseDown(with event: NSEvent) { onMouseDown?(event) }
    override public func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override public func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Bolha de fala: cartão branco com traço preto, também com cara de adesivo.
/// Dono de uma `CALayer` em vez de subclasse, para ficar fora das regras de
/// isolamento dos inicializadores de `CALayer`.
@MainActor
final class BubbleLayer {
    let layer = CALayer()
    private let shape = CAShapeLayer()
    private let text = CATextLayer()
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init() {
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        shape.fillColor = NSColor.white.cgColor
        shape.strokeColor = NSColor.black.cgColor
        shape.lineWidth = 2
        shape.lineJoin = .round
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.2
        shape.shadowRadius = 2
        shape.shadowOffset = CGSize(width: 0, height: -1)
        text.font = font
        text.fontSize = 12
        text.foregroundColor = NSColor.black.cgColor
        text.alignmentMode = .center
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        text.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(shape)
        layer.addSublayer(text)
        layer.isHidden = true
    }

    var isHidden: Bool {
        get { layer.isHidden }
        set { layer.isHidden = newValue }
    }

    func show(text string: String, anchor: CGPoint, in container: CGRect) {
        let size = (string as NSString).size(withAttributes: [.font: font])
        let w = ceil(size.width) + 16, h = ceil(size.height) + 10, tail = 6.0
        var origin = CGPoint(x: anchor.x - w / 2, y: anchor.y + tail)
        origin.x = min(max(origin.x, container.minX + 4), container.maxX - w - 4)
        origin.y = min(origin.y, container.maxY - h - 4)
        layer.frame = CGRect(x: origin.x, y: origin.y - tail, width: w, height: h + tail)

        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 0, y: tail, width: w, height: h), cornerWidth: 8, cornerHeight: 8)
        let tx = min(max(anchor.x - origin.x, 10), w - 10)
        path.move(to: CGPoint(x: tx - 4, y: tail + 1))
        path.addLine(to: CGPoint(x: tx, y: 0))
        path.addLine(to: CGPoint(x: tx + 4, y: tail + 1))
        shape.frame = layer.bounds
        shape.path = path
        text.string = string
        text.frame = CGRect(x: 0, y: tail + 4, width: w, height: h - 8)
    }
}
#endif
