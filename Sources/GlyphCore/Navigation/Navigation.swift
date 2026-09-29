import Foundation

/// Como ir de um ponto a outro.
public enum Move: Sendable, Equatable {
    /// Andar (ou se pendurar e ir de mão em mão, no teto) na mesma superfície.
    case walk
    /// Sair andando pela borda e cair. `dir`: -1 esquerda, +1 direita.
    case drop(dir: Double)
    /// Pulo balístico com esta velocidade inicial.
    case jump(Vec2)
    /// Escalar uma parede até o topo (janela) ou até o teto (borda de tela).
    case climb(WallKey)
    /// Pular reto para cima e agarrar o teto.
    case grabCeiling(vy: Double)
    /// Soltar do teto.
    case release
}

/// Um passo do caminho. `surface` é onde o corpo deve estar ao terminar.
public struct PathStep: Sendable, Equatable {
    public var move: Move
    public var from: Vec2
    public var to: Vec2
    public var surface: SurfaceKind

    public init(move: Move, from: Vec2, to: Vec2, surface: SurfaceKind) {
        self.move = move
        self.from = from
        self.to = to
        self.surface = surface
    }
}

public enum NavGoal: Sendable, Equatable {
    /// O ponto andável mais próximo deste.
    case point(Vec2)
    /// Um x numa superfície específica.
    case surface(SurfaceKind, x: Double)
    /// A casa desta tela (pendurado no teto, embaixo da notch).
    case home(screen: UInt32)
}

/// Grafo de navegação: nós são pontos em segmentos; arestas são andar,
/// pular, cair, escalar e se pendurar. Reconstruído quando o mundo muda.
public struct NavGraph: Sendable {
    struct Node: Hashable {
        var seg: Int
        var x: Double
    }

    struct Edge {
        var from: Node
        var to: Node
        var move: Move
        var cost: Double
    }

    public let world: World
    public let config: PhysicsConfig
    let transitions: [Edge]

    /// Velocidade usada para a heurística do A*: maior que qualquer
    /// deslocamento real, para a heurística ser admissível.
    static let heuristicSpeed = 900.0

    public init(world: World, config: PhysicsConfig = PhysicsConfig()) {
        self.world = world
        self.config = config
        self.transitions = NavGraph.buildTransitions(world, config)
    }

    public var transitionCount: Int { transitions.count }

    private static func q(_ x: Double) -> Double { (x * 2).rounded() / 2 }

    private static func buildTransitions(_ w: World, _ c: PhysicsConfig) -> [Edge] {
        let segs = w.segments
        let half = w.metrics.halfWidth
        let reach = c.maxJumpHeight * 0.8
        var out: [Edge] = []
        func node(_ i: Int, _ x: Double) -> Node { Node(seg: i, x: q(segs[i].clampX(x))) }
        func highestBelow(x: Double, y: Double, excluding: Int? = nil) -> Int? {
            segs.indices
                .filter { $0 != excluding && !segs[$0].kind.isCeiling && segs[$0].contains(x: x) && segs[$0].y < y - 1 }
                .max { segs[$0].y < segs[$1].y }
        }

        for (i, a) in segs.enumerated() where !a.kind.isCeiling {
            // Cair pelas bordas.
            for dir in [-1.0, 1.0] {
                let edge = dir < 0 ? a.x0 : a.x1
                let landX = edge + dir * 4
                if let j = highestBelow(x: landX, y: a.y) {
                    let t = JumpSolver.fallTime(height: a.y - segs[j].y, gravity: c.gravity)
                    out.append(Edge(from: node(i, edge), to: node(j, landX), move: .drop(dir: dir), cost: t + 0.2))
                }
            }

            // Pular para outras plataformas.
            for (j, b) in segs.enumerated() where j != i && !b.kind.isCeiling {
                let overlap = Span(a.x0 + half, a.x1 - half).intersect(Span(b.x0 + half, b.x1 - half))
                var from: Vec2, to: Vec2
                if let o = overlap {
                    guard b.y > a.y + 1 else { continue } // para baixo, só caindo
                    let x = (o.lo + o.hi) / 2
                    from = Vec2(x, a.y)
                    to = Vec2(x, b.y)
                } else {
                    let dir: Double = b.midX > a.midX ? 1 : -1
                    from = Vec2(dir > 0 ? a.x1 - 2 : a.x0 + 2, a.y)
                    to = Vec2(b.clampX(dir > 0 ? b.x0 + half + 2 : b.x1 - half - 2), b.y)
                }
                guard abs(to.x - from.x) <= 420, let sol = JumpSolver.solve(from: from, to: to, config: c) else { continue }
                out.append(Edge(from: node(i, from.x), to: node(j, to.x), move: .jump(sol.velocity), cost: sol.flightTime + 0.3))
            }

            // Agarrar o teto da mesma tela.
            if let screen = w.screen(containing: Vec2(a.midX, a.y)), let ci = segs.firstIndex(where: { $0.kind == .ceiling(screen: screen.id) }) {
                let h = segs[ci].y - w.metrics.height - a.y
                if h > 0, let vy = JumpSolver.verticalVelocity(height: h + 2, config: c) {
                    let x = a.midX
                    out.append(Edge(from: node(i, x), to: node(ci, x), move: .grabCeiling(vy: vy), cost: 2 * vy / c.gravity + 0.3))
                }
            }
        }

        // Escalar paredes.
        for wall in w.walls {
            let cx = wall.climbX(halfWidth: half)
            let target: Int?
            switch wall.key.owner {
            case let .window(id):
                let inner = wall.x - Double(wall.side) * half
                target = segs.firstIndex { $0.kind == .window(id) && $0.contains(x: inner) && abs($0.y - wall.y1) < 1 }
            case let .screen(id):
                target = segs.firstIndex { $0.kind == .ceiling(screen: id) }
            }
            guard let t = target else { continue }
            let tx: Double = wall.key.owner.isScreen ? cx : wall.x - Double(wall.side) * half
            for (i, a) in segs.enumerated() where i != t && !a.kind.isCeiling && a.contains(x: cx)
                && a.y >= wall.y0 - reach && a.y < wall.y1 - 1 {
                let climb = (wall.y1 - max(a.y, wall.y0)) / c.climbSpeed
                out.append(Edge(from: node(i, cx), to: node(t, tx), move: .climb(wall.key), cost: climb + 0.4))
            }
        }

        // Soltar do teto.
        for (ci, ceil) in segs.enumerated() where ceil.kind.isCeiling {
            for (i, a) in segs.enumerated() where !a.kind.isCeiling {
                for x in [a.x0 + half, a.midX, a.x1 - half] where ceil.contains(x: x) && a.contains(x: x) {
                    guard highestBelow(x: x, y: ceil.y - w.metrics.height + 1) == i else { continue }
                    let t = JumpSolver.fallTime(height: ceil.y - w.metrics.height - a.y, gravity: c.gravity)
                    out.append(Edge(from: node(ci, x), to: node(i, x), move: .release, cost: t + 0.2))
                }
            }
        }
        return out
    }

    // MARK: - Consultas

    /// Índice do segmento onde o corpo está, se estiver apoiado.
    public func segmentIndex(for s: BodyState) -> Int? {
        switch s.support {
        case let .ground(kind):
            return world.segments.firstIndex { $0.kind == kind && $0.contains(x: s.position.x, margin: 1) && abs($0.y - s.position.y) < 2 }
        case let .ceiling(screen):
            return world.segments.firstIndex { $0.kind == .ceiling(screen: screen) }
        default:
            return nil
        }
    }

    func resolve(_ goal: NavGoal) -> Node? {
        let segs = world.segments
        switch goal {
        case let .surface(kind, x):
            guard let i = segs.firstIndex(where: { $0.kind == kind && $0.contains(x: x, margin: 1) })
                ?? segs.firstIndex(where: { $0.kind == kind }) else { return nil }
            return Node(seg: i, x: NavGraph.q(segs[i].clampX(x)))
        case let .home(screen):
            guard let s = world.screens.first(where: { $0.id == screen }),
                  let i = segs.firstIndex(where: { $0.kind == .ceiling(screen: screen) }) else { return nil }
            return Node(seg: i, x: NavGraph.q(segs[i].clampX(s.home.midX, inset: world.metrics.halfWidth)))
        case let .point(p):
            let half = world.metrics.halfWidth
            let best = segs.indices.filter { !segs[$0].kind.isCeiling }.min { i, j in
                func d(_ k: Int) -> Double {
                    let s = segs[k]
                    let dx = p.x - s.clampX(p.x, inset: half), dy = p.y - s.y
                    // Prefere superfícies abaixo do ponto (ficar em cima da janela, não embaixo).
                    return (dx * dx + dy * dy).squareRoot() + (dy < 0 ? 200 : 0)
                }
                return d(i) < d(j)
            }
            guard let i = best else { return nil }
            return Node(seg: i, x: NavGraph.q(segs[i].clampX(p.x, inset: half)))
        }
    }

    /// Caminho de menor custo (A*). `nil` se não houver.
    public func path(from s: BodyState, to goal: NavGoal) -> [PathStep]? {
        guard let si = segmentIndex(for: s), let goalNode = resolve(goal) else { return nil }
        let start = Node(seg: si, x: NavGraph.q(s.position.x))
        return path(from: start, to: goalNode)
    }

    func path(from start: Node, to goal: Node) -> [PathStep]? {
        let segs = world.segments
        if start == goal { return [] }

        // Pontos-chave por segmento: pontas de transições, início e fim.
        var keys: [Int: Set<Double>] = [:]
        for e in transitions {
            keys[e.from.seg, default: []].insert(e.from.x)
            keys[e.to.seg, default: []].insert(e.to.x)
        }
        keys[start.seg, default: []].insert(start.x)
        keys[goal.seg, default: []].insert(goal.x)

        var adj: [Node: [Edge]] = [:]
        for e in transitions { adj[e.from, default: []].append(e) }
        for (seg, xs) in keys {
            let sorted = xs.sorted()
            let speed = segs[seg].kind.isCeiling ? config.hangSpeed : config.walkSpeed
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let na = Node(seg: seg, x: a), nb = Node(seg: seg, x: b)
                let cost = (b - a) / speed
                adj[na, default: []].append(Edge(from: na, to: nb, move: .walk, cost: cost))
                adj[nb, default: []].append(Edge(from: nb, to: na, move: .walk, cost: cost))
            }
        }

        func pos(_ n: Node) -> Vec2 { Vec2(n.x, segs[n.seg].y) }
        let goalPos = pos(goal)
        func h(_ n: Node) -> Double { pos(n).distance(to: goalPos) / NavGraph.heuristicSpeed }

        var open = MinHeap<Node>()
        var g: [Node: Double] = [start: 0]
        var came: [Node: Edge] = [:]
        var closed: Set<Node> = []
        open.push(start, priority: h(start))
        while let cur = open.pop() {
            if cur == goal { break }
            if !closed.insert(cur).inserted { continue }
            for e in adj[cur] ?? [] {
                let ng = g[cur]! + e.cost
                if ng < g[e.to] ?? .infinity {
                    g[e.to] = ng
                    came[e.to] = e
                    open.push(e.to, priority: ng + h(e.to))
                }
            }
        }
        guard came[goal] != nil else { return nil }

        var edges: [Edge] = []
        var n = goal
        while n != start, let e = came[n] {
            edges.append(e)
            n = e.from
        }
        edges.reverse()

        // Junta caminhadas seguidas.
        var steps: [PathStep] = []
        for e in edges {
            let step = PathStep(move: e.move, from: pos(e.from), to: pos(e.to), surface: segs[e.to.seg].kind)
            if e.move == .walk, let last = steps.last, last.move == .walk, last.surface == step.surface {
                steps[steps.count - 1].to = step.to
            } else {
                steps.append(step)
            }
        }
        return steps
    }
}

/// Heap binário mínimo, suficiente para o A*.
struct MinHeap<T> {
    private var items: [(T, Double)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ item: T, priority: Double) {
        items.append((item, priority))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard items[i].1 < items[p].1 else { break }
            items.swapAt(i, p)
            i = p
        }
    }

    mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, items[l].1 < items[m].1 { m = l }
            if r < items.count, items[r].1 < items[m].1 { m = r }
            if m == i { break }
            items.swapAt(i, m)
            i = m
        }
        return top.0
    }
}
