import Foundation

/// Exporta o estilo adesivo para SVG: a mesma geometria (`StickerShapes`) que
/// o app desenha com Core Animation. Usado para a arte do README, a galeria de
/// estados e os ícones, sem precisar de um Mac.
public enum SVGRenderer {
    /// Área do mundo mostrada no SVG. `origin` é o canto inferior esquerdo.
    public struct Canvas: Sendable, Equatable {
        public var origin: Vec2
        public var width: Double
        public var height: Double
        /// Pontos de SVG por ponto de mundo.
        public var scale: Double

        public init(origin: Vec2 = .zero, width: Double, height: Double, scale: Double = 1) {
            self.origin = origin
            self.width = width
            self.height = height
            self.scale = scale
        }

        public var pixelWidth: Double { width * scale }
        public var pixelHeight: Double { height * scale }

        /// Mundo (y para cima) → SVG (y para baixo).
        func map(_ p: Vec2) -> (Double, Double) {
            ((p.x - origin.x) * scale, (height - (p.y - origin.y)) * scale)
        }
    }

    public static func num(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%.1f", r)
    }

    static func polylineData(_ pts: [Vec2], _ c: Canvas, close: Bool = false) -> String {
        guard let first = pts.first else { return "" }
        let (x0, y0) = c.map(first)
        var s = "M\(num(x0)) \(num(y0))"
        for p in pts.dropFirst() {
            let (x, y) = c.map(p)
            s += "L\(num(x)) \(num(y))"
        }
        if close { s += "Z" }
        return s
    }

    static func discData(_ center: Vec2, _ r: Double, _ c: Canvas) -> String {
        let (x, y) = c.map(center)
        let rr = r * c.scale
        return "M\(num(x - rr)) \(num(y))a\(num(rr)) \(num(rr)) 0 1 0 \(num(2 * rr)) 0a\(num(rr)) \(num(rr)) 0 1 0 \(num(-2 * rr)) 0Z"
    }

    /// Os quatro caminhos de um quadro: papel (preenchimento), contorno branco,
    /// tinta e Dots.
    public struct Layers: Sendable, Equatable {
        public var fill = ""
        public var outline = ""
        public var ink = ""
        public var dots = ""
        public var dotBorders = ""
    }

    public static func layers(_ shapes: StickerShapes, _ c: Canvas, style: StickerStyle = .default) -> Layers {
        var l = Layers()
        l.fill = shapes.fills.map { polylineData($0, c, close: true) }.joined()
        let strokes = shapes.strokes.map { polylineData($0, c) }.joined()
        l.outline = strokes
        l.ink = strokes
        let visible = shapes.discs.filter { $0.opacity > 0.01 }
        l.dots = visible.map { discData($0.center, $0.radius, c) }.joined()
        l.dotBorders = visible.map { discData($0.center, $0.radius + style.outlineWidth * 0.6, c) }.joined()
        return l
    }

    static func styleAttrs(_ style: StickerStyle, _ c: Canvas) -> (outline: String, ink: String) {
        (##"fill="none" stroke="#fff" stroke-width="\##(num(style.outlineStrokeWidth * c.scale))" stroke-linecap="round" stroke-linejoin="round""##,
         ##"fill="none" stroke="#111" stroke-width="\##(num(style.inkWidth * c.scale))" stroke-linecap="round" stroke-linejoin="round""##)
    }

    static func filterDef(_ style: StickerStyle, _ c: Canvas) -> String {
        ##"<filter id="sticker-shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="\##(num(style.shadowOffset.x * c.scale))" dy="\##(num(-style.shadowOffset.y * c.scale))" stdDeviation="\##(num(style.shadowRadius * c.scale / 2))" flood-color="#000" flood-opacity="\##(style.shadowOpacity)"/></filter>"##
    }

    /// Um grupo `<g>` com o adesivo inteiro.
    public static func group(_ shapes: StickerShapes, _ c: Canvas, style: StickerStyle = .default, opacity: Double = 1) -> String {
        let l = layers(shapes, c, style: style)
        let (o, i) = styleAttrs(style, c)
        let op = opacity < 0.999 ? ##" opacity="\##(num(opacity))""## : ""
        return """
        <g filter="url(#sticker-shadow)"\(op)><path d="\(l.fill)" fill="#fff"/><path d="\(l.outline)" \(o)/><path d="\(l.dotBorders)" fill="#fff"/><path d="\(l.ink)" \(i)/><path d="\(l.dots)" fill="#111"/></g>
        """
    }

    /// Bolha de fala como adesivo: cartão branco, traço preto, rabinho.
    public static func bubble(_ text: String, anchor: Vec2, _ c: Canvas) -> String {
        let (ax, ay) = c.map(anchor)
        let s = c.scale
        let w = (Double(text.count) * 6.6 + 16) * s, h = 22 * s, tail = 6 * s
        let x = min(max(ax - w / 2, 4), c.pixelWidth - w - 4)
        let y = ay - tail - h
        let tx = min(max(ax, x + 10 * s), x + w - 10 * s)
        let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <g filter="url(#sticker-shadow)"><path d="M\(num(x + 8 * s)) \(num(y))H\(num(x + w - 8 * s))Q\(num(x + w)) \(num(y)) \(num(x + w)) \(num(y + 8 * s))V\(num(y + h - 8 * s))Q\(num(x + w)) \(num(y + h)) \(num(x + w - 8 * s)) \(num(y + h))H\(num(tx + 4 * s))L\(num(tx)) \(num(y + h + tail))L\(num(tx - 4 * s)) \(num(y + h))H\(num(x + 8 * s))Q\(num(x)) \(num(y + h)) \(num(x)) \(num(y + h - 8 * s))V\(num(y + 8 * s))Q\(num(x)) \(num(y)) \(num(x + 8 * s)) \(num(y))Z" fill="#fff" stroke="#111" stroke-width="\(num(2 * s))" stroke-linejoin="round"/><text x="\(num(x + w / 2))" y="\(num(y + h / 2 + 4 * s))" text-anchor="middle" font-family="ui-rounded, 'SF Pro Rounded', 'Nunito', system-ui, sans-serif" font-size="\(num(12 * s))" font-weight="600" fill="#111">\(esc)</text></g>
        """
    }

    /// Documento SVG completo.
    public static func document(_ c: Canvas, body: String, background: String? = nil, title: String? = nil) -> String {
        let bg = background.map { ##"<rect width="100%" height="100%" fill="\##($0)"/>"## } ?? ""
        let t = title.map { "<title>\($0)</title>" } ?? ""
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(c.pixelWidth))" height="\(num(c.pixelHeight))" viewBox="0 0 \(num(c.pixelWidth)) \(num(c.pixelHeight))">\(t)<defs>\(filterDef(.default, c))</defs>\(bg)\(body)</svg>

        """
    }

    /// Um quadro estático do Glyph.
    public static func render(_ d: GlyphDrawing, _ c: Canvas, background: String? = nil, title: String? = nil) -> String {
        var body = group(StickerShapes.build(d), c, opacity: d.opacity)
        if let b = d.bubble {
            body += bubble(b, anchor: d.position + d.skeleton.headCenter + Vec2(0, d.skeleton.headRadius + 8), c)
        }
        return document(c, body: body, background: background, title: title)
    }

    /// Animação SVG (SMIL): cada camada troca de caminho a cada quadro, sem
    /// interpolar — "em dois", como no app. Toca em loop no navegador e no GitHub.
    public static func animate(_ frames: [StickerShapes], fps: Double, _ c: Canvas, style: StickerStyle = .default,
                               background: String? = nil, scenery: String = "", title: String? = nil) -> String {
        precondition(!frames.isEmpty)
        let ls = frames.map { layers($0, c, style: style) }
        let dur = num(Double(frames.count) / fps)
        func anim(_ key: KeyPath<Layers, String>) -> String {
            // Caminho vazio quebra alguns renderizadores: usa um ponto invisível.
            let values = ls.map { $0[keyPath: key].isEmpty ? "M-10 -10" : $0[keyPath: key] }.joined(separator: ";")
            return ##"<animate attributeName="d" dur="\##(dur)s" repeatCount="indefinite" calcMode="discrete" values="\##(values)"/>"##
        }
        func first(_ key: KeyPath<Layers, String>) -> String { ls[0][keyPath: key].isEmpty ? "M-10 -10" : ls[0][keyPath: key] }
        let (o, i) = styleAttrs(style, c)
        let body = """
        \(scenery)<g filter="url(#sticker-shadow)"><path d="\(first(\.fill))" fill="#fff">\(anim(\.fill))</path><path d="\(first(\.outline))" \(o)>\(anim(\.outline))</path><path d="\(first(\.dotBorders))" fill="#fff">\(anim(\.dotBorders))</path><path d="\(first(\.ink))" \(i)>\(anim(\.ink))</path><path d="\(first(\.dots))" fill="#111">\(anim(\.dots))</path></g>
        """
        return document(c, body: body, background: background, title: title)
    }

    /// Janela desenhada como moldura simples (cenário das animações).
    public static func window(_ r: Rect, _ c: Canvas, title: String? = nil) -> String {
        let (x, y) = c.map(Vec2(r.minX, r.maxY))
        let w = r.width * c.scale, h = r.height * c.scale, s = c.scale
        var out = ##"<g><rect x="\##(num(x))" y="\##(num(y))" width="\##(num(w))" height="\##(num(h))" rx="\##(num(8 * s))" fill="#fbfaf7" stroke="#d9d6cf" stroke-width="\##(num(1.2 * s))"/>"##
        out += ##"<path d="M\##(num(x)) \##(num(y + 22 * s))H\##(num(x + w))" stroke="#e6e3dc" stroke-width="\##(num(1 * s))"/>"##
        for (k, color) in ["#ff5f57", "#febc2e", "#28c840"].enumerated() {
            out += ##"<circle cx="\##(num(x + (12 + Double(k) * 14) * s))" cy="\##(num(y + 11 * s))" r="\##(num(4.5 * s))" fill="\##(color)"/>"##
        }
        if let title {
            out += ##"<text x="\##(num(x + w / 2))" y="\##(num(y + 15 * s))" text-anchor="middle" font-family="system-ui, sans-serif" font-size="\##(num(10 * s))" fill="#8a867e">\##(title)</text>"##
        }
        return out + "</g>"
    }
}
