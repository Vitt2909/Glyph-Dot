import Foundation

/// Que superfície é esta.
public enum SurfaceKind: Sendable, Hashable {
    /// Borda de cima de uma janela.
    case window(UInt32)
    /// Chão da tela (topo do Dock ou borda de baixo).
    case floor(screen: UInt32)
    /// Linha de baixo da barra de menu, onde ele anda pendurado.
    case ceiling(screen: UInt32)

    public var isCeiling: Bool {
        if case .ceiling = self { return true }
        return false
    }

    public var windowID: UInt32? {
        if case let .window(id) = self { return id }
        return nil
    }
}

/// Trecho horizontal andável. Plataformas são de mão única: só se pousa
/// vindo de cima.
public struct Segment: Sendable, Hashable {
    public var kind: SurfaceKind
    public var y: Double
    public var x0: Double
    public var x1: Double

    public init(kind: SurfaceKind, y: Double, x0: Double, x1: Double) {
        self.kind = kind
        self.y = y
        self.x0 = x0
        self.x1 = x1
    }

    public var length: Double { x1 - x0 }
    public var midX: Double { (x0 + x1) / 2 }

    public func contains(x: Double, margin: Double = 0) -> Bool {
        x >= x0 - margin && x <= x1 + margin
    }

    public func clampX(_ x: Double, inset: Double = 0) -> Double {
        let lo = x0 + inset, hi = x1 - inset
        return lo <= hi ? x.clamped(lo, hi) : midX
    }
}

/// Identidade estável de uma parede entre reconstruções do mundo.
public struct WallKey: Sendable, Hashable {
    public enum Owner: Sendable, Hashable {
        case window(UInt32)
        case screen(UInt32)
    }

    public var owner: Owner
    /// -1: lado esquerdo (a face externa aponta para -x). +1: lado direito.
    public var side: Int

    public init(owner: Owner, side: Int) {
        self.owner = owner
        self.side = side
    }
}

/// Trecho vertical escalável: lateral de janela ou borda de tela.
public struct Wall: Sendable, Hashable {
    public var key: WallKey
    public var x: Double
    public var y0: Double
    public var y1: Double
    /// Bordas de tela seguram o corpo; laterais de janela não.
    public var solid: Bool
    /// Degrau entre telas: o topo desta parede é o chão da tela vizinha, e
    /// quem escala sobe nele (do lado de fora).
    public var ledge: SurfaceKind?

    public init(key: WallKey, x: Double, y0: Double, y1: Double, solid: Bool, ledge: SurfaceKind? = nil) {
        self.key = key
        self.x = x
        self.y0 = y0
        self.y1 = y1
        self.solid = solid
        self.ledge = ledge
    }

    public var side: Int { key.side }

    /// Onde fica o centro do corpo ao escalar, do lado de fora.
    public func climbX(halfWidth: Double) -> Double {
        key.owner.isScreen ? x - Double(side) * halfWidth : x + Double(side) * halfWidth
    }
}

extension WallKey.Owner {
    public var isScreen: Bool {
        if case .screen = self { return true }
        return false
    }
}

/// Onde uma superfície continua em outra tela: chão com chão ou teto com teto
/// na mesma altura (lado a lado), ou o teto de uma tela com o chão da tela de
/// cima (empilhadas).
public struct Passage: Sendable, Hashable {
    public enum Direction: String, Sendable, Hashable { case left, right, up, down }

    public var from: SurfaceKind
    public var to: SurfaceKind
    public var direction: Direction
    /// Lado a lado: o x da emenda. Empilhadas: o meio do trecho.
    public var x: Double
    /// Empilhadas: onde dá para passar (já descontada a largura do corpo).
    public var span: Span

    public init(from: SurfaceKind, to: SurfaceKind, direction: Direction, x: Double, span: Span) {
        self.from = from
        self.to = to
        self.direction = direction
        self.x = x
        self.span = span
    }

    public var isSide: Bool { direction == .left || direction == .right }
    public var sign: Double { direction == .left ? -1 : 1 }
}

/// Medidas do corpo que o mundo precisa conhecer.
public struct BodyMetrics: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double = SkeletonMetrics().width, height: Double = SkeletonMetrics().height) {
        self.width = width
        self.height = height
    }

    public var halfWidth: Double { width / 2 }
}

/// O mundo físico do Glyph, construído a partir de um `WorldSnapshot`.
///
/// Uma plataforma só existe onde a borda de cima da janela está visível: de
/// cada topo subtraímos as janelas à frente na ordem Z.
public struct World: Sendable {
    public let snapshot: WorldSnapshot
    public let metrics: BodyMetrics
    public private(set) var segments: [Segment] = []
    public private(set) var walls: [Wall] = []
    /// Topo inteiro de cada janela, sem oclusão (usado para fugir de quem cobre).
    public private(set) var rawTops: [UInt32: Segment] = [:]
    /// Retângulo de cada janela, para consultas de cobertura.
    public private(set) var frames: [UInt32: Rect] = [:]
    /// Índice Z (0 = frente) de cada janela.
    public private(set) var zIndex: [UInt32: Int] = [:]
    /// Continuações entre telas.
    public private(set) var passages: [Passage] = []

    public init(_ snapshot: WorldSnapshot, metrics: BodyMetrics = BodyMetrics()) {
        self.snapshot = snapshot
        self.metrics = metrics
        build()
    }

    public var screens: [ScreenInfo] { snapshot.screens }

    public var bounds: Rect {
        snapshot.screens.map(\.frame).reduce(nil as Rect?) { acc, r in acc.map { $0.union(r) } ?? r } ?? .zero
    }

    private mutating func build() {
        let minLen = metrics.width
        let windows = snapshot.windows
        for (i, w) in windows.enumerated() {
            frames[w.id] = w.frame
            zIndex[w.id] = i
        }

        for s in snapshot.screens {
            segments.append(Segment(kind: .floor(screen: s.id), y: s.floorY, x0: s.frame.minX, x1: s.frame.maxX))
            segments.append(Segment(kind: .ceiling(screen: s.id), y: s.ceilingY, x0: s.frame.minX, x1: s.frame.maxX))
            for side in [-1, 1] {
                let x = side < 0 ? s.frame.minX : s.frame.maxX
                // Onde outra tela continua deste lado, não é parede. O que
                // sobra é parede: acima do teto da vizinha, ou um degrau
                // abaixo do chão dela (telas de alturas diferentes).
                let neighbors = snapshot.screens.filter { o in
                    o.id != s.id && abs((side < 0 ? o.frame.maxX : o.frame.minX) - x) < 1
                }
                let open = neighbors.map { Span($0.floorY, $0.ceilingY) }
                for piece in Span.subtract(Span(s.floorY, s.ceilingY), open) where piece.length > 0.5 {
                    let ledge = neighbors.first { abs($0.floorY - piece.hi) < 1 }.map { SurfaceKind.floor(screen: $0.id) }
                    walls.append(Wall(key: WallKey(owner: .screen(s.id), side: side), x: x,
                                      y0: piece.lo, y1: piece.hi, solid: true, ledge: ledge))
                }
            }
        }
        buildPassages()

        for (i, w) in windows.enumerated() {
            let f = w.frame
            let front = windows[..<i].map(\.frame)
            let y = f.maxY

            // Topo: só dentro de telas onde há espaço para o corpo em pé.
            var tops: [Span] = []
            for s in snapshot.screens where y > s.floorY + 1 && y + metrics.height <= s.ceilingY {
                if let span = Span(f.minX, f.maxX).intersect(Span(s.frame.minX, s.frame.maxX)) { tops.append(span) }
            }
            if let raw = tops.max(by: { $0.length < $1.length }) {
                rawTops[w.id] = Segment(kind: .window(w.id), y: y, x0: raw.lo, x1: raw.hi)
            }
            let cuts = front.filter { $0.minY <= y && $0.maxY >= y }.map { Span($0.minX, $0.maxX) }
            for top in tops {
                for piece in Span.subtract(top, cuts) where piece.length >= minLen {
                    segments.append(Segment(kind: .window(w.id), y: y, x0: piece.lo, x1: piece.hi))
                }
            }

            // Laterais: partes visíveis, dentro da faixa chão…teto da tela.
            for side in [-1, 1] {
                let x = side < 0 ? f.minX : f.maxX
                guard let s = snapshot.screens.first(where: { x >= $0.frame.minX && x <= $0.frame.maxX }) else { continue }
                guard let span = Span(f.minY, f.maxY).intersect(Span(s.floorY, s.ceilingY)) else { continue }
                let vcuts = front.filter { $0.minX <= x && $0.maxX >= x }.map { Span($0.minY, $0.maxY) }
                for piece in Span.subtract(span, vcuts) where piece.length >= metrics.height / 2 {
                    walls.append(Wall(key: WallKey(owner: .window(w.id), side: side), x: x,
                                      y0: piece.lo, y1: piece.hi, solid: false))
                }
            }
        }
    }

    private mutating func buildPassages() {
        let half = metrics.halfWidth
        for s in snapshot.screens {
            for o in snapshot.screens where o.id != s.id {
                // Lado a lado: `o` começa onde `s` termina.
                if abs(o.frame.minX - s.frame.maxX) < 1 {
                    if abs(o.floorY - s.floorY) < 1 {
                        add(.floor(screen: s.id), .floor(screen: o.id), x: s.frame.maxX)
                    }
                    if abs(o.ceilingY - s.ceilingY) < 1 {
                        add(.ceiling(screen: s.id), .ceiling(screen: o.id), x: s.frame.maxX)
                    }
                }
                // Empilhadas: `o` fica em cima de `s`. Passa entre o teto de
                // baixo e o chão de cima, onde as duas se sobrepõem.
                if abs(o.frame.minY - s.frame.maxY) < 1,
                   let overlap = Span(s.frame.minX, s.frame.maxX).intersect(Span(o.frame.minX, o.frame.maxX)),
                   overlap.length >= metrics.width * 2 {
                    let span = Span(overlap.lo + half, overlap.hi - half)
                    let mid = (span.lo + span.hi) / 2
                    passages.append(Passage(from: .ceiling(screen: s.id), to: .floor(screen: o.id), direction: .up, x: mid, span: span))
                    passages.append(Passage(from: .floor(screen: o.id), to: .ceiling(screen: s.id), direction: .down, x: mid, span: span))
                }
            }
        }

        func add(_ a: SurfaceKind, _ b: SurfaceKind, x: Double) {
            let span = Span(x - 1, x + 1)
            passages.append(Passage(from: a, to: b, direction: .right, x: x, span: span))
            passages.append(Passage(from: b, to: a, direction: .left, x: x, span: span))
        }
    }

    // MARK: - Consultas

    /// Passagem lateral atravessada ao ir de `x0` a `x1` saindo de `kind`.
    public func sidePassage(from kind: SurfaceKind, x0: Double, x1: Double) -> Passage? {
        passages.first { p in
            guard p.from == kind else { return false }
            switch p.direction {
            case .right: return x0 <= p.x + 1 && x1 > p.x
            case .left: return x0 >= p.x - 1 && x1 < p.x
            default: return false
            }
        }
    }

    /// Passagem lateral saindo de `kind` para este lado.
    public func sidePassage(from kind: SurfaceKind, direction: Passage.Direction) -> Passage? {
        passages.first { $0.from == kind && $0.direction == direction }
    }

    /// Passagem vertical saindo de `kind` que cobre `x`.
    public func verticalPassage(from kind: SurfaceKind, x: Double) -> Passage? {
        passages.first { $0.from == kind && !$0.isSide && x >= $0.span.lo - 1 && x <= $0.span.hi + 1 }
    }

    /// O pedaço de parede mais perto da altura `y` (uma borda de tela pode ter
    /// mais de um).
    public func nearestWall(_ key: WallKey, to y: Double) -> Wall? {
        walls.filter { $0.key == key }.min { a, b in
            func d(_ w: Wall) -> Double { y < w.y0 ? w.y0 - y : (y > w.y1 ? y - w.y1 : 0) }
            return d(a) < d(b)
        }
    }

    public func screen(containing p: Vec2) -> ScreenInfo? {
        snapshot.screens.first { $0.frame.contains(p) }
            ?? snapshot.screens.min { distance($0.frame, p) < distance($1.frame, p) }
    }

    private func distance(_ r: Rect, _ p: Vec2) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    public var standable: [Segment] { segments.filter { !$0.kind.isCeiling } }

    /// Superfície em pé mais alta sob `p` (inclusive exatamente em `p.y`).
    public func segmentBelow(_ p: Vec2, tolerance: Double = 0.5) -> Segment? {
        standable
            .filter { $0.contains(x: p.x) && $0.y <= p.y + tolerance }
            .max { $0.y < $1.y }
    }

    /// Superfície de um tipo que passa por `x` perto de `y`.
    public func segment(_ kind: SurfaceKind, x: Double, nearY y: Double, tolerance: Double = 2) -> Segment? {
        segments.first { $0.kind == kind && $0.contains(x: x) && abs($0.y - y) <= tolerance }
    }

    public func wall(_ key: WallKey) -> Wall? {
        walls.first { $0.key == key && $0.y1 - $0.y0 > 0 }
    }

    /// Parede de um tipo que cobre a altura `y`.
    public func wall(_ key: WallKey, at y: Double) -> Wall? {
        walls.first { $0.key == key && y >= $0.y0 - 1 && y <= $0.y1 + 1 }
    }

    public func ceiling(for screen: UInt32) -> Segment? {
        segments.first { $0.kind == .ceiling(screen: screen) }
    }

    /// Janela à frente de `window` que cobre o ponto, se houver.
    public func cover(of window: UInt32, at p: Vec2) -> (id: UInt32, frame: Rect)? {
        guard let z = zIndex[window] else { return nil }
        for w in snapshot.windows.prefix(z) where w.frame.minX <= p.x && w.frame.maxX >= p.x
            && w.frame.minY <= p.y && w.frame.maxY >= p.y {
            return (w.id, w.frame)
        }
        return nil
    }

    /// Alguma janela (de qualquer profundidade) cobre este ponto?
    public func isCovered(_ p: Vec2) -> Bool {
        snapshot.windows.contains { $0.frame.contains(p) }
    }
}

/// Intervalo fechado em uma dimensão.
public struct Span: Sendable, Hashable {
    public var lo: Double
    public var hi: Double

    public init(_ lo: Double, _ hi: Double) {
        self.lo = lo
        self.hi = hi
    }

    public var length: Double { hi - lo }

    public func intersect(_ o: Span) -> Span? {
        let l = max(lo, o.lo), h = min(hi, o.hi)
        return h > l ? Span(l, h) : nil
    }

    /// `base` menos a união de `cuts`, em ordem crescente.
    public static func subtract(_ base: Span, _ cuts: [Span]) -> [Span] {
        var pieces = [base]
        for c in cuts {
            var next: [Span] = []
            for p in pieces {
                if c.hi <= p.lo || c.lo >= p.hi {
                    next.append(p)
                    continue
                }
                if c.lo > p.lo { next.append(Span(p.lo, c.lo)) }
                if c.hi < p.hi { next.append(Span(c.hi, p.hi)) }
            }
            pieces = next
        }
        return pieces.sorted { $0.lo < $1.lo }
    }
}
