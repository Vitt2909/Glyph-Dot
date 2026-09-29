import Foundation

/// Tudo que o renderer precisa para desenhar um quadro do Glyph.
///
/// O corpo (macOS) só transforma isto em `CAShapeLayer`s; toda a decisão de
/// pose, Dot e olhos acontece no Core, onde é testável.
public struct GlyphDrawing: Sendable, Equatable {
    /// Posição dos pés, em coordenadas globais.
    public var position: Vec2
    /// Esqueleto em coordenadas locais (origem nos pés).
    public var skeleton: SkeletonPoints
    public var dot: DotDrawing
    public var eyes: EyesDrawing?
    /// Quadro usado pelo line boil.
    public var boilFrame: Int
    public var bubble: String?
    /// Pontos de orçamento carregados ao lado (somem a cada ação).
    public var budgetDots: Int
    /// Opacidade geral (esmaece ao dormir, some ao entrar em casa).
    public var opacity: Double

    public init(position: Vec2, skeleton: SkeletonPoints, dot: DotDrawing, eyes: EyesDrawing? = nil,
                boilFrame: Int = 0, bubble: String? = nil, budgetDots: Int = 0, opacity: Double = 1) {
        self.position = position
        self.skeleton = skeleton
        self.dot = dot
        self.eyes = eyes
        self.boilFrame = boilFrame
        self.bubble = bubble
        self.budgetDots = budgetDots
        self.opacity = opacity
    }

    /// Caixa que envolve o desenho, em coordenadas globais (usada como hitbox).
    public var bounds: Rect {
        let pts = skeleton.allPoints
        let r = skeleton.headRadius
        var minX = pts.map(\.x).min() ?? 0, maxX = pts.map(\.x).max() ?? 0
        var minY = pts.map(\.y).min() ?? 0, maxY = pts.map(\.y).max() ?? 0
        minX = Swift.min(minX, skeleton.headCenter.x - r)
        maxX = Swift.max(maxX, skeleton.headCenter.x + r)
        minY = Swift.min(minY, skeleton.headCenter.y - r)
        maxY = Swift.max(maxY, skeleton.headCenter.y + r)
        let pad = StickerStyle.default.outlineStrokeWidth / 2
        return Rect(minX: position.x + minX - pad, minY: position.y + minY - pad,
                    maxX: position.x + maxX + pad, maxY: position.y + maxY + pad)
    }

    /// O Glyph parado, em repouso. É o que o M0 desenha.
    public static func standing(at position: Vec2, facing: Double = 1) -> GlyphDrawing {
        let sk = ForwardKinematics.solve(.rest, facing: facing)
        return GlyphDrawing(position: position, skeleton: sk,
                            dot: DotDrawing(center: sk.headCenter, radius: SkeletonMetrics().dotRadius))
    }
}

public struct DotDrawing: Sendable, Equatable {
    /// Centro do Dot, em coordenadas locais.
    public var center: Vec2
    public var radius: Double
    public var opacity: Double
    /// Partículas extras (órbita ao pensar, rastro ao trabalhar), locais.
    public var particles: [Vec2]
    /// `!` acima da cabeça.
    public var alert: Bool
    /// `z z z`.
    public var sleeping: Bool

    public init(center: Vec2, radius: Double, opacity: Double = 1, particles: [Vec2] = [],
                alert: Bool = false, sleeping: Bool = false) {
        self.center = center
        self.radius = radius
        self.opacity = opacity
        self.particles = particles
        self.alert = alert
        self.sleeping = sleeping
    }
}

/// Olhos só aparecem quando expressam algo: dois traços curtos.
public struct EyesDrawing: Sendable, Equatable {
    public enum Style: String, Sendable { case open, blink, squint }
    /// Deslocamento do olhar dentro da cabeça, -1…1 em cada eixo.
    public var look: Vec2
    public var style: Style

    public init(look: Vec2 = .zero, style: Style = .open) {
        self.look = look
        self.style = style
    }

    /// Os dois traços, em coordenadas locais, dado o centro e o raio da cabeça.
    public func strokes(headCenter c: Vec2, headRadius r: Double) -> [[Vec2]] {
        let lx = look.x.clamped(-1, 1) * r * 0.35, ly = look.y.clamped(-1, 1) * r * 0.3
        let h = style == .open ? r * 0.36 : (style == .squint ? r * 0.12 : 0.01)
        return [-1.0, 1.0].map { side in
            let x = c.x + lx + side * r * 0.32
            return [Vec2(x, c.y + ly - h / 2), Vec2(x, c.y + ly + h / 2)]
        }
    }
}
