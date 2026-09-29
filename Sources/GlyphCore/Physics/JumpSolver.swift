import Foundation

/// Resolve pulos: dado um ponto de saída e um de chegada, acha a velocidade
/// inicial de um arco balístico que chega lá, dentro dos limites do corpo.
public enum JumpSolver {
    public struct Solution: Sendable, Equatable {
        public var velocity: Vec2
        public var flightTime: Double
        public var apexY: Double
    }

    /// Folgas de altura testadas acima do ponto mais alto, da menor para a maior.
    /// Arco baixo parece mais natural; se exigir velocidade horizontal demais,
    /// tenta um arco mais alto (mais tempo no ar).
    public static let clearances: [Double] = [10, 24, 44, 70, 100]

    public static func solve(from a: Vec2, to b: Vec2, config: PhysicsConfig) -> Solution? {
        let g = config.gravity
        for clearance in clearances {
            let apex = max(a.y, b.y) + clearance
            let up = apex - a.y, down = apex - b.y
            let vy = (2 * g * up).squareRoot()
            guard vy <= config.maxJumpVy + 1e-9 else { return nil }
            let t = vy / g + (2 * down / g).squareRoot()
            let vx = (b.x - a.x) / t
            if abs(vx) <= config.maxJumpVx {
                return Solution(velocity: Vec2(vx, vy), flightTime: t, apexY: apex)
            }
        }
        return nil
    }

    /// Velocidade para subir exatamente `height` (para agarrar o teto).
    public static func verticalVelocity(height: Double, config: PhysicsConfig) -> Double? {
        guard height >= 0 else { return nil }
        let v = (2 * config.gravity * height).squareRoot()
        return v <= config.maxJumpVy ? v : nil
    }

    /// Posição no instante `t` de um arco (sem velocidade terminal).
    public static func position(from a: Vec2, velocity v: Vec2, gravity g: Double, at t: Double) -> Vec2 {
        Vec2(a.x + v.x * t, a.y + v.y * t - 0.5 * g * t * t)
    }

    /// Tempo de queda livre por `height`.
    public static func fallTime(height: Double, gravity g: Double) -> Double {
        (2 * max(height, 0) / g).squareRoot()
    }
}
