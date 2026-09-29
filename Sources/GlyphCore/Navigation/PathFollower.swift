import Foundation

/// Transforma um caminho em comandos de controle, passo a passo.
public struct PathFollower: Sendable {
    public enum Status: Sendable, Equatable {
        case running
        case done
        /// O corpo não está onde o passo espera: é hora de replanejar.
        case failed
    }

    public private(set) var steps: [PathStep]
    public private(set) var index = 0
    /// Distância a partir da qual ele corre em vez de andar.
    public var runThreshold = 140.0
    public var arriveTolerance = 1.5
    private var launched = false

    public init(steps: [PathStep]) { self.steps = steps }

    public var current: PathStep? { index < steps.count ? steps[index] : nil }
    public var isDone: Bool { index >= steps.count }

    /// Distância que ainda falta, aproximada.
    public var remainingDistance: Double {
        steps[min(index, steps.count)...].reduce(0) { $0 + $1.from.distance(to: $1.to) }
    }

    private mutating func advance() {
        index += 1
        launched = false
    }

    private func onSurface(_ s: BodyState, _ k: SurfaceKind) -> Bool {
        switch (s.support, k) {
        case let (.ground(a), b): return a == b
        case let (.ceiling(a), .ceiling(b)): return a == b
        default: return false
        }
    }

    private func walk(toward x: Double, from s: BodyState, allowRun: Bool = true) -> Control {
        var c = Control()
        let dx = x - s.position.x
        c.moveX = abs(dx) <= arriveTolerance ? 0 : (dx > 0 ? 1 : -1)
        // Chega devagar: reduz nos últimos pontos para não passar do alvo.
        if abs(dx) < 6 { c.moveX *= max(abs(dx) / 6, 0.3) }
        c.run = allowRun && abs(dx) > runThreshold
        return c
    }

    public mutating func control(for s: BodyState, world: World, config: PhysicsConfig) -> (Control, Status) {
        while let step = current {
            switch step.move {
            case .walk:
                guard onSurface(s, step.surface) else { return (Control(), .failed) }
                if abs(step.to.x - s.position.x) <= arriveTolerance {
                    advance()
                    continue
                }
                return (walk(toward: step.to.x, from: s, allowRun: !step.surface.isCeiling), .running)

            case let .drop(dir):
                if onSurface(s, step.surface), launched {
                    advance()
                    continue
                }
                if s.support.isGrounded {
                    if launched { return (Control(), .failed) } // caiu em outro lugar
                    var c = Control()
                    c.moveX = dir
                    return (c, .running)
                }
                launched = true
                var c = Control()
                let dx = step.to.x - s.position.x
                c.moveX = abs(dx) < 2 ? 0 : (dx > 0 ? 0.5 : -0.5)
                return (c, .running)

            case let .jump(v):
                if launched {
                    if onSurface(s, step.surface) {
                        advance()
                        continue
                    }
                    if s.support.isGrounded { return (Control(), .failed) }
                    return (Control(), .running) // balístico
                }
                guard s.support.isGrounded else { return (Control(), .running) }
                if abs(step.from.x - s.position.x) > 3 {
                    return (walk(toward: step.from.x, from: s, allowRun: false), .running)
                }
                var c = Control()
                c.jump = v
                launched = true
                return (c, .running)

            case let .climb(key):
                if onSurface(s, step.surface) {
                    advance()
                    continue
                }
                var c = Control()
                switch s.support {
                case .wall:
                    c.climb = 1
                    return (c, .running)
                case .ground:
                    if launched { return (Control(), .failed) }
                    if abs(step.from.x - s.position.x) > 3 {
                        return (walk(toward: step.from.x, from: s, allowRun: false), .running)
                    }
                    guard let wall = world.walls.first(where: { $0.key == key }) else { return (Control(), .failed) }
                    c.attachWall = key
                    if s.position.y + 1 < wall.y0 {
                        // A parede começa acima: um pulinho para alcançar.
                        c.jump = Vec2(0, JumpSolver.verticalVelocity(height: wall.y0 - s.position.y + 6, config: config) ?? config.maxJumpVy)
                        launched = true
                    }
                    return (c, .running)
                case .air:
                    c.attachWall = key
                    return (c, .running)
                default:
                    return (Control(), .failed)
                }

            case let .grabCeiling(vy):
                if onSurface(s, step.surface) {
                    advance()
                    continue
                }
                var c = Control()
                c.grabCeiling = true
                if s.support.isGrounded {
                    if launched { return (Control(), .failed) }
                    if abs(step.from.x - s.position.x) > 3 {
                        return (walk(toward: step.from.x, from: s, allowRun: false), .running)
                    }
                    c.jump = Vec2(0, vy)
                    launched = true
                }
                return (c, .running)

            case .release:
                if onSurface(s, step.surface) {
                    advance()
                    continue
                }
                if case .ceiling = s.support {
                    if abs(step.from.x - s.position.x) > arriveTolerance {
                        return (walk(toward: step.from.x, from: s, allowRun: false), .running)
                    }
                    var c = Control()
                    c.release = true
                    launched = true
                    return (c, .running)
                }
                if s.support.isGrounded { return (Control(), .failed) }
                return (Control(), .running)
            }
        }
        return (Control(), .done)
    }
}
