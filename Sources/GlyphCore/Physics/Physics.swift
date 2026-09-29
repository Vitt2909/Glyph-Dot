import Foundation

/// Números da física. Unidades: pontos e segundos.
public struct PhysicsConfig: Sendable, Equatable {
    public var dt = 1.0 / 60
    public var gravity = 1800.0
    public var terminalVelocity = 1500.0
    public var walkSpeed = 70.0
    public var runSpeed = 190.0
    /// Corrida de fuga (janela maximizando por cima).
    public var fleeSpeed = 320.0
    public var groundAccel = 900.0
    public var airControl = 250.0
    public var maxJumpVy = 620.0
    public var maxJumpVx = 260.0
    public var climbSpeed = 60.0
    public var hangSpeed = 50.0
    /// Pequena tolerância para pular logo depois de sair da borda.
    public var coyoteTime = 0.08
    /// Velocidade máxima ao ser solto pelo cursor.
    public var maxThrow = 700.0

    public init() {}

    /// Altura máxima de um pulo parado.
    public var maxJumpHeight: Double { maxJumpVy * maxJumpVy / (2 * gravity) }
}

/// Onde o corpo está apoiado.
public enum Support: Sendable, Equatable {
    case ground(SurfaceKind)
    case wall(WallKey)
    case ceiling(screen: UInt32)
    case air
    case carried

    public var surface: SurfaceKind? {
        if case let .ground(k) = self { return k }
        return nil
    }

    public var isGrounded: Bool { surface != nil }
}

/// Estado físico do corpo. `position` é o ponto entre os pés.
public struct BodyState: Sendable, Equatable {
    public var position: Vec2
    public var velocity: Vec2 = .zero
    public var support: Support = .air
    /// +1 olhando para a direita, -1 para a esquerda.
    public var facing: Double = 1
    /// Tempo desde que saiu do chão (para o coyote time).
    public var airTime: Double = 0
    /// Última superfície em que esteve em pé.
    public var lastSurface: SurfaceKind?
    /// Uma janela à frente cobre o ponto onde ele está em pé.
    public var coveredBy: UInt32?

    public init(position: Vec2) { self.position = position }
}

/// Comando de controle para um passo.
public struct Control: Sendable, Equatable {
    /// -1…1: esquerda/direita.
    public var moveX = 0.0
    public var run = false
    public var flee = false
    /// Velocidade inicial de um pulo, se for para pular agora.
    public var jump: Vec2?
    /// Durante o voo, agarra o teto se encostar nele.
    public var grabCeiling = false
    /// -1…1: descer/subir na parede.
    public var climb = 0.0
    /// Começa a escalar esta parede (precisa estar ao alcance).
    public var attachWall: WallKey?
    /// Solta da parede ou do teto.
    public var release = false

    public init() {}
}

public enum PhysicsEvent: Sendable, Equatable {
    case jumped
    case landed(impact: Double, on: SurfaceKind)
    case leftGround(SurfaceKind)
    case lostSupport
    case grabbedWall(WallKey)
    case mantled(SurfaceKind)
    case grabbedCeiling
    case bonked
    case hitScreenEdge
}

/// Física cinemática 2D com passo fixo. Determinística.
public struct PhysicsSimulator: Sendable {
    public var config: PhysicsConfig
    public var metrics: BodyMetrics

    public init(config: PhysicsConfig = PhysicsConfig(), metrics: BodyMetrics = BodyMetrics()) {
        self.config = config
        self.metrics = metrics
    }

    /// Um passo de `config.dt`.
    public func step(_ s: inout BodyState, _ c: Control, in world: World) -> [PhysicsEvent] {
        var events: [PhysicsEvent] = []
        let dt = config.dt

        if c.moveX != 0, s.support != .carried { s.facing = c.moveX > 0 ? 1 : -1 }

        // Pulo: do chão, ou logo depois de sair dele (coyote time).
        if let j = c.jump, s.support.isGrounded || (s.support == .air && s.airTime < config.coyoteTime && s.lastSurface != nil) {
            s.velocity = Vec2(j.x.clamped(-config.maxJumpVx, config.maxJumpVx), min(j.y, config.maxJumpVy))
            s.support = .air
            s.airTime = config.coyoteTime // não pula de novo no ar
            events.append(.jumped)
        }

        switch s.support {
        case let .ground(kind):
            stepGround(&s, kind, c, world, dt, &events)
        case let .wall(key):
            stepWall(&s, key, c, world, dt, &events)
        case let .ceiling(screen):
            stepCeiling(&s, screen, c, world, dt, &events)
        case .air:
            stepAir(&s, c, world, dt, &events)
        case .carried:
            break
        }
        return events
    }

    private func speed(_ c: Control) -> Double {
        c.flee ? config.fleeSpeed : (c.run ? config.runSpeed : config.walkSpeed)
    }

    private func approach(_ v: Double, _ target: Double, _ rate: Double) -> Double {
        v < target ? min(v + rate, target) : max(v - rate, target)
    }

    private func stepGround(_ s: inout BodyState, _ kind: SurfaceKind, _ c: Control, _ w: World, _ dt: Double,
                            _ events: inout [PhysicsEvent]) {
        if let key = c.attachWall, let wall = w.wall(key, at: s.position.y + 1) {
            let wx = wall.climbX(halfWidth: metrics.halfWidth)
            if abs(wx - s.position.x) <= metrics.width {
                s.position.x = wx
                s.velocity = .zero
                s.support = .wall(key)
                events.append(.grabbedWall(key))
                return
            }
        }

        let target = c.moveX.clamped(-1, 1) * speed(c)
        s.velocity.x = approach(s.velocity.x, target, config.groundAccel * dt * (c.flee ? 3 : 1))
        s.velocity.y = 0
        var nx = s.position.x + s.velocity.x * dt
        if let limit = solidLimit(from: s.position.x, to: nx, y: s.position.y, in: w) {
            nx = limit
            s.velocity.x = 0
            events.append(.hitScreenEdge)
        }

        // Superfície visível sob os pés?
        if let seg = w.segment(kind, x: nx, nearY: s.position.y) {
            s.position = Vec2(nx, seg.y)
            s.coveredBy = nil
            s.lastSurface = kind
            return
        }
        // Uma janela à frente cobriu o ponto onde ele JÁ estava (maximizar,
        // janela nova por cima): o topo continua lá embaixo e ele corre por
        // ele até sair. Andar de um trecho visível para um coberto é sair da
        // borda, e aí ele cai.
        let wasVisible = w.segment(kind, x: s.position.x, nearY: s.position.y) != nil
        if !wasVisible, let id = kind.windowID, let raw = w.rawTops[id], raw.contains(x: nx), abs(raw.y - s.position.y) <= 2,
           let cover = w.cover(of: id, at: Vec2(nx, raw.y)) {
            s.position = Vec2(nx, raw.y)
            s.coveredBy = cover.id
            s.lastSurface = kind
            return
        }
        // Saiu da borda, ou a plataforma sumiu/moveu: cai.
        s.position.x = nx
        s.support = .air
        s.airTime = 0
        s.coveredBy = nil
        if w.segments.contains(where: { $0.kind == kind }) || w.rawTops[kind.windowID ?? 0] != nil {
            events.append(.leftGround(kind))
        } else {
            events.append(.lostSupport)
        }
    }

    private func stepAir(_ s: inout BodyState, _ c: Control, _ w: World, _ dt: Double, _ events: inout [PhysicsEvent]) {
        s.airTime += dt
        // Agarrar uma parede no meio do pulo.
        if let key = c.attachWall, let wall = w.wall(key, at: s.position.y),
           abs(wall.climbX(halfWidth: metrics.halfWidth) - s.position.x) <= metrics.width {
            s.position.x = wall.climbX(halfWidth: metrics.halfWidth)
            s.velocity = .zero
            s.support = .wall(key)
            events.append(.grabbedWall(key))
            return
        }
        if c.moveX != 0 {
            let target = c.moveX.clamped(-1, 1) * max(abs(s.velocity.x), speed(c))
            s.velocity.x = approach(s.velocity.x, target, config.airControl * dt)
        }
        let old = s.position
        let vy0 = s.velocity.y
        s.velocity.y = max(vy0 - config.gravity * dt, -config.terminalVelocity)
        s.position.y += (vy0 + s.velocity.y) / 2 * dt
        s.position.x += s.velocity.x * dt

        // Bordas de tela seguram.
        if let limit = solidLimit(from: old.x, to: s.position.x, y: s.position.y, in: w) {
            s.position.x = limit
            s.velocity.x = 0
            events.append(.hitScreenEdge)
        }

        // Teto: agarra ou bate a cabeça.
        if s.velocity.y > 0, let screen = w.screen(containing: s.position), let ceil = w.ceiling(for: screen.id) {
            let head = s.position.y + metrics.height
            if head >= ceil.y {
                s.position.y = ceil.y - metrics.height
                if c.grabCeiling {
                    s.velocity = .zero
                    s.support = .ceiling(screen: screen.id)
                    events.append(.grabbedCeiling)
                    return
                }
                s.velocity.y = 0
                events.append(.bonked)
            }
        }

        // Pouso: plataformas de mão única, só vindo de cima.
        if s.velocity.y <= 0 {
            let landing = w.standable
                .filter { $0.contains(x: s.position.x) && old.y >= $0.y - 0.01 && s.position.y <= $0.y }
                .max { $0.y < $1.y }
            if let seg = landing {
                let impact = -s.velocity.y
                s.position.y = seg.y
                s.velocity = Vec2(s.velocity.x * 0.3, 0)
                s.support = .ground(seg.kind)
                s.lastSurface = seg.kind
                s.airTime = 0
                events.append(.landed(impact: impact, on: seg.kind))
                return
            }
        }

        // Rede de segurança: nunca cai abaixo do chão de nenhuma tela.
        if let screen = w.screen(containing: s.position), s.position.y < screen.floorY - 1 {
            s.position.y = screen.floorY
            s.velocity = .zero
            s.support = .ground(.floor(screen: screen.id))
            s.lastSurface = .floor(screen: screen.id)
            events.append(.landed(impact: 0, on: .floor(screen: screen.id)))
        }
    }

    /// Se ir de `x0` a `x1` atravessa uma borda de tela, devolve o limite.
    private func solidLimit(from x0: Double, to x1: Double, y: Double, in w: World) -> Double? {
        for wall in w.walls where wall.solid && y >= wall.y0 - metrics.height && y <= wall.y1 + metrics.height {
            let limit = wall.climbX(halfWidth: metrics.halfWidth)
            if wall.side < 0, x1 < limit, x0 >= limit - 1 { return limit }
            if wall.side > 0, x1 > limit, x0 <= limit + 1 { return limit }
        }
        return nil
    }

    private func stepWall(_ s: inout BodyState, _ key: WallKey, _ c: Control, _ w: World, _ dt: Double,
                          _ events: inout [PhysicsEvent]) {
        guard let wall = w.wall(key, at: s.position.y), !c.release else {
            s.support = .air
            s.airTime = config.coyoteTime
            s.velocity = Vec2(Double(key.side) * 30, 0)
            events.append(.lostSupport)
            return
        }
        s.position.x = wall.climbX(halfWidth: metrics.halfWidth)
        s.velocity = Vec2(0, c.climb.clamped(-1, 1) * config.climbSpeed)
        s.position.y += s.velocity.y * dt

        // Na borda da tela a subida termina com a cabeça no teto.
        let top = key.owner.isScreen ? wall.y1 - metrics.height : wall.y1
        if s.position.y >= top {
            // Chegou em cima: sobe na janela, ou agarra o teto na borda da tela.
            switch key.owner {
            case let .window(id):
                let inner = wall.x - Double(key.side) * metrics.halfWidth
                if let seg = w.segment(.window(id), x: inner, nearY: wall.y1) {
                    s.position = Vec2(inner, seg.y)
                    s.support = .ground(seg.kind)
                    s.lastSurface = seg.kind
                    s.velocity = .zero
                    events.append(.mantled(seg.kind))
                } else {
                    s.position.y = wall.y1
                }
            case let .screen(id):
                if let ceil = w.ceiling(for: id), wall.y1 >= ceil.y - 1 {
                    s.position.y = ceil.y - metrics.height
                    s.support = .ceiling(screen: id)
                    s.velocity = .zero
                    events.append(.grabbedCeiling)
                } else {
                    s.position.y = top
                }
            }
        } else if s.position.y <= wall.y0 {
            s.position.y = wall.y0
            if let seg = w.segmentBelow(Vec2(s.position.x, s.position.y), tolerance: 1), abs(seg.y - s.position.y) < 2 {
                s.support = .ground(seg.kind)
                s.lastSurface = seg.kind
                s.velocity = .zero
            } else {
                s.support = .air
                s.airTime = config.coyoteTime
            }
        }
    }

    private func stepCeiling(_ s: inout BodyState, _ screen: UInt32, _ c: Control, _ w: World, _ dt: Double,
                             _ events: inout [PhysicsEvent]) {
        guard let ceil = w.ceiling(for: screen), !c.release else {
            s.support = .air
            s.airTime = config.coyoteTime
            s.velocity = .zero
            events.append(.lostSupport)
            return
        }
        s.velocity = Vec2(c.moveX.clamped(-1, 1) * config.hangSpeed, 0)
        s.position.x = (s.position.x + s.velocity.x * dt).clamped(ceil.x0 + metrics.halfWidth, ceil.x1 - metrics.halfWidth)
        s.position.y = ceil.y - metrics.height
    }

    // MARK: - Mundo mudou

    /// Aplica mudanças de janelas a quem está apoiado nelas: arrastar a
    /// janela leva o Glyph junto.
    public func apply(_ diff: WorldDiff, to s: inout BodyState) {
        switch s.support {
        case let .ground(.window(id)):
            if let ch = diff.changed[id] {
                let d = WorldDiff.topLeftDelta(old: ch.old, new: ch.new)
                s.position += d
                s.position.x = s.position.x.clamped(ch.new.minX, ch.new.maxX)
            }
        case let .wall(key):
            if case let .window(id) = key.owner, let ch = diff.changed[id] {
                s.position += WorldDiff.topLeftDelta(old: ch.old, new: ch.new)
                if key.side > 0 { s.position.x += ch.new.width - ch.old.width }
            }
        default:
            break
        }
    }

    /// Solto pelo cursor com velocidade de arremesso.
    public func release(_ s: inout BodyState, throwVelocity v: Vec2) {
        let len = v.length
        s.velocity = len > config.maxThrow ? v * (config.maxThrow / len) : v
        s.support = .air
        s.airTime = config.coyoteTime
    }
}
