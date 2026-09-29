import Foundation

/// Camadas procedurais aplicadas por cima dos clipes.
public enum Procedural {
    /// Respiração: 0,25 Hz, bem sutil.
    public static func breath(time: Double, amount: Double = 1) -> Pose {
        let s = sin(2 * .pi * 0.25 * time) * amount
        return Pose([Joint.torso.rawValue: s * 0.8, PoseChannel.rootDY.rawValue: s * 0.35])
    }

    /// Ângulo de cabeça (graus, relativo ao tronco) para olhar na direção `dir`
    /// (local, já considerando para onde ele está virado). Limitado a ±`limit`.
    public static func lookAngle(toward dir: Vec2, facing: Double, limit: Double = 25) -> Double {
        guard dir.length > 1e-6 else { return 0 }
        // Olhar para cima (+y) inclina a cabeça para trás; para a frente, nada.
        let forward = dir.x * (facing < 0 ? -1 : 1)
        let pitch = atan2(dir.y, max(abs(forward), 1e-6)).degrees
        return (pitch * 0.35).clamped(-limit, limit) * (forward >= 0 ? 1 : -1)
    }
}

/// IK de dois ossos no plano, na convenção do esqueleto
/// (0 = para baixo, positivo anti-horário; o inferior é relativo ao superior).
public enum TwoBoneIK {
    /// Ângulos (superior, inferior) para a ponta alcançar `target` a partir de
    /// `root`. Se estiver longe demais, estica em direção ao alvo.
    /// `bend`: +1 dobra o joelho/cotovelo para um lado, -1 para o outro.
    public static func solve(root: Vec2, target: Vec2, upper l1: Double, lower l2: Double, bend: Double = 1) -> (Double, Double) {
        let d = target - root
        let dist = min(max(d.length, abs(l1 - l2) + 1e-6), l1 + l2 - 1e-6)
        // Ângulo da reta raiz→alvo, na convenção "0 = para baixo".
        let base = atan2(d.x, -d.y)
        // Lei dos cossenos.
        let cosA = ((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist)).clamped(-1, 1)
        let cosB = ((l1 * l1 + l2 * l2 - dist * dist) / (2 * l1 * l2)).clamped(-1, 1)
        let a = acos(cosA), b = acos(cosB)
        let s = bend >= 0 ? 1.0 : -1.0
        let upper = base - s * a
        let lower = s * (.pi - b)
        return (upper.degrees, lower.degrees)
    }
}

/// Mola amortecida para o squash & stretch: amassa no pouso, estica no pulo,
/// e volta a 1 com um pouco de overshoot.
public struct SquashSpring: Sendable, Equatable {
    public var value = 1.0
    public var velocity = 0.0
    public var stiffness = 420.0
    public var damping = 16.0

    public init() {}

    public mutating func kick(_ amount: Double) { velocity += amount }

    public mutating func set(_ v: Double) {
        value = v
        velocity = 0
    }

    public mutating func step(_ dt: Double, target: Double = 1) {
        let a = -stiffness * (value - target) - damping * velocity
        velocity += a * dt
        value = (value + velocity * dt).clamped(0.6, 1.4)
    }
}

/// Anima o Dot conforme o modo. O Dot muda de comportamento, não de cor.
public struct DotAnimator: Sendable {
    public var metrics = SkeletonMetrics()

    public init() {}

    /// - Parameters:
    ///   - time: tempo global (s).
    ///   - since: tempo desde que o modo começou (s).
    ///   - target: ponto de interesse em coordenadas locais (evento, janela alvo).
    ///   - planned: passos planejados (para a órbita ao pensar).
    public func draw(mode: DotMode, speed: Double = 1, time: Double, since: Double,
                     head: Vec2, target: Vec2? = nil, planned: Int = 4) -> DotDrawing {
        let r = metrics.dotRadius
        var d = DotDrawing(center: head, radius: r)
        switch mode {
        case .steady:
            d.radius = r * (1 + 0.06 * sin(2 * .pi * 0.25 * time))
        case .pulse:
            d.radius = r * (1 + 0.18 * sin(2 * .pi * speed * time))
        case .glance:
            if let t = target { d.center = head + (t - head).normalized * 1.6 }
        case .orbit:
            // Sai da cabeça e orbita; nº de partículas ≈ log₂ dos passos planejados.
            let n = max(1, Int(log2(Double(max(planned, 2))).rounded()))
            let out = min(since / 0.3, 1) * (metrics.headRadius + 5)
            let w = 2.2 * speed
            d.center = head + Vec2(cos(time * w), sin(time * w)) * out
            d.particles = (1..<(n + 1)).map { i in
                let a = time * w + Double(i) * 2 * .pi / Double(n + 1)
                return head + Vec2(cos(a), sin(a)) * out
            }
        case .trail:
            guard let t = target else { break }
            let dir = t - head
            let count = 4
            d.particles = (1...count).map { i in
                let phase = (Double(i) / Double(count + 1) + time * 0.8 * speed).truncatingRemainder(dividingBy: 1)
                return head + dir * phase
            }
        case .blink:
            // Pisca 2× e para.
            if since < 0.8 {
                d.opacity = Int(since / 0.2) % 2 == 0 ? 1 : 0.15
            }
        case .alert:
            d.alert = true
        case .shrink:
            d.radius = r * 0.7
        case .fade:
            d.opacity = 0.35
            d.sleeping = true
            d.radius = r * (1 + 0.04 * sin(2 * .pi * 0.15 * time))
        case .split:
            let out = min(since / 0.6, 1)
            d.particles = [head + Vec2(metrics.headRadius * 2.5 * out, metrics.headRadius * 1.5 * out)]
        }
        return d
    }
}
