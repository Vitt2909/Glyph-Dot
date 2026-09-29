import Foundation

/// Geometria final de um quadro, já com line boil, em coordenadas globais.
///
/// O renderer desenha:
/// 1. `fills` em branco (o papel do adesivo) e `strokes` em branco com
///    `StickerStyle.outlineStrokeWidth` — o contorno recortado;
/// 2. `strokes` em preto com `StickerStyle.inkWidth`;
/// 3. `discs` em preto por cima (o Dot e partículas), com borda branca.
public struct StickerShapes: Sendable, Equatable {
    public struct Disc: Sendable, Equatable {
        public var center: Vec2
        public var radius: Double
        public var opacity: Double
    }

    public var strokes: [[Vec2]] = []
    public var fills: [[Vec2]] = []
    public var discs: [Disc] = []

    public init() {}

    public static func build(_ d: GlyphDrawing, style: StickerStyle = .default, seed: UInt64 = 0x61_79_68_67) -> StickerShapes {
        let boil = LineBoil(seed: seed, style: style)
        var out = StickerShapes()
        var index = 0
        func add(_ local: [Vec2], closed: Bool = false, fill: Bool = false, subdivide: Double = 4) {
            let dense = Polyline.subdivide(local, maxSegment: subdivide)
            let boiled = boil.apply(dense, baseIndex: index, frame: d.boilFrame).map { $0 + d.position }
            index += dense.count + 17
            var pts = boiled
            if closed, let first = pts.first { pts.append(first) }
            out.strokes.append(pts)
            if fill { out.fills.append(pts) }
        }

        let sk = d.skeleton
        for s in sk.strokes { add(s) }
        add(Polyline.circle(center: sk.headCenter, radius: sk.headRadius, segments: 18), closed: true, fill: true, subdivide: 100)

        if let eyes = d.eyes {
            for s in eyes.strokes(headCenter: sk.headCenter, headRadius: sk.headRadius) { add(s, subdivide: 100) }
        }

        let top = sk.headCenter.y + sk.headRadius
        if d.dot.alert {
            // `!`: um traço e um ponto acima da cabeça.
            let x = sk.headCenter.x
            add([Vec2(x, top + 13), Vec2(x, top + 6)], subdivide: 100)
            out.discs.append(.init(center: Vec2(x, top + 3) + d.position, radius: 1.3, opacity: 1))
        }
        if d.dot.sleeping {
            // `z z z` subindo em diagonal, desenhados como zigue-zague.
            for i in 0..<3 {
                let s = 3.0 + Double(i)
                let o = Vec2(sk.headCenter.x + 8 + Double(i) * 6, top + 2 + Double(i) * 7)
                add([o + Vec2(0, s), o + Vec2(s, s), o, o + Vec2(s, 0)], subdivide: 100)
            }
        }

        let dotOpacity = d.dot.opacity.clamped(0, 1)
        out.discs.append(.init(center: d.dot.center + d.position, radius: d.dot.radius, opacity: dotOpacity))
        for p in d.dot.particles {
            out.discs.append(.init(center: p + d.position, radius: d.dot.radius * 0.55, opacity: dotOpacity))
        }
        if let held = d.held {
            let s = held.shapes(at: d.heldAnchor + d.position, scale: 0.7, frame: d.boilFrame)
            out.fills += s.fills
            out.strokes += s.strokes
            out.discs += s.discs
        }
        for i in 0..<d.budgetDots {
            let p = Vec2(sk.headCenter.x + sk.headRadius + 6 + Double(i) * 5, sk.headCenter.y)
            out.discs.append(.init(center: p + d.position, radius: 1.2, opacity: 1))
        }
        return out
    }
}

public enum Polyline {
    /// Insere pontos para que nenhum trecho passe de `maxSegment`.
    /// Sem isso o boil só mexeria nas juntas e o traço ficaria reto demais.
    public static func subdivide(_ pts: [Vec2], maxSegment: Double) -> [Vec2] {
        guard pts.count > 1, maxSegment > 0 else { return pts }
        var out: [Vec2] = [pts[0]]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let n = Swift.max(1, Int((a.distance(to: b) / maxSegment).rounded(.up)))
            for i in 1...n { out.append(Vec2.lerp(a, b, Double(i) / Double(n))) }
        }
        return out
    }

    public static func circle(center: Vec2, radius: Double, segments: Int) -> [Vec2] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return center + Vec2(cos(a), sin(a)) * radius
        }
    }
}
