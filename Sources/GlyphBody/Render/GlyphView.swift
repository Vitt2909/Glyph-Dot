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
    private let paperFill = CAShapeLayer() // preenchimento branco da cabeça
    private let paper = CAShapeLayer()     // contorno branco
    private let ink = CAShapeLayer()       // traço preto
    private let dotPaper = CAShapeLayer()  // borda branca do Dot
    private let dotInk = CAShapeLayer()    // Dot
    private var bubbles: [BubbleLayer] = []

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
        for l in [paperFill, paper, ink, dotPaper, dotInk] as [CAShapeLayer] {
            l.lineCap = .round
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "opacity": NSNull()]
            sticker.addSublayer(l)
        }
        sticker.actions = ["opacity": NSNull()]
        layer?.addSublayer(sticker)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    override public var isFlipped: Bool { false }

    // Camadas adicionadas à mão não herdam a escala da tela: sem isto o
    // traço fica borrado em Retina.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [sticker, paperFill, paper, ink, dotPaper, dotInk] as [CALayer] { l.contentsScale = scale }
    }

    private func applyStyle() {
        paperFill.fillColor = NSColor.white.cgColor
        paperFill.strokeColor = nil
        paper.strokeColor = NSColor.white.cgColor
        paper.fillColor = nil
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
        show(drawing.map { [$0] } ?? [])
    }

    /// Mostra vários Glyphs (o principal e os especialistas) nas mesmas camadas.
    public func show(_ drawings: [GlyphDrawing]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard !drawings.isEmpty else {
            sticker.isHidden = true
            bubbles.forEach { $0.isHidden = true }
            return
        }
        sticker.isHidden = false
        sticker.opacity = Float(drawings[0].opacity)

        let strokePath = CGMutablePath(), fillPath = CGMutablePath()
        let dots = CGMutablePath(), dotBorders = CGMutablePath()
        for d in drawings where d.opacity > 0.02 {
            let shapes = StickerShapes.build(d, style: style)
            for s in shapes.strokes { addPolyline(s, to: strokePath) }
            for f in shapes.fills { addPolyline(f, to: fillPath, close: true) }
            for disc in shapes.discs where disc.opacity > 0.01 {
                let c = local(disc.center)
                dots.addEllipse(in: CGRect(x: c.x - disc.radius, y: c.y - disc.radius, width: 2 * disc.radius, height: 2 * disc.radius))
                let r = disc.radius + style.outlineWidth * 0.6
                dotBorders.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }
        paperFill.path = fillPath
        paper.path = strokePath
        ink.path = strokePath
        dotPaper.path = dotBorders
        dotInk.path = dots
        dotInk.opacity = Float(drawings[0].dot.opacity)

        // Uma bolha por Glyph que estiver falando.
        let speaking = drawings.filter { $0.bubble != nil }
        while bubbles.count < speaking.count {
            let b = BubbleLayer()
            layer?.addSublayer(b.layer)
            bubbles.append(b)
        }
        for (i, b) in bubbles.enumerated() {
            guard i < speaking.count, let text = speaking[i].bubble else { b.isHidden = true; continue }
            let d = speaking[i]
            b.isHidden = false
            let head = local(d.skeleton.headCenter + d.position)
            b.show(text: text, anchor: CGPoint(x: head.x, y: head.y + d.skeleton.headRadius + 10), in: bounds)
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
