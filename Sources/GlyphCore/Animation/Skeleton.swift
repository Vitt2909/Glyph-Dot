import Foundation

/// Articulações do esqueleto procedural.
///
/// Convenção de ângulo (graus): 0 aponta para baixo; positivo gira no sentido
/// anti-horário (em direção a +x na tela). Braços e pernas usam lados
/// anatômicos: com o Glyph de frente para você, `armR` fica à sua esquerda,
/// então levantar o braço direito para fora é um ângulo negativo.
/// `*.lower` é relativo ao segmento superior. `torso` é a inclinação a partir
/// da vertical e `head` é relativo ao tronco.
public enum Joint: String, Sendable, CaseIterable, Codable {
    case torso
    case head
    case armLUpper = "armL.upper"
    case armLLower = "armL.lower"
    case armRUpper = "armR.upper"
    case armRLower = "armR.lower"
    case legLUpper = "legL.upper"
    case legLLower = "legL.lower"
    case legRUpper = "legR.upper"
    case legRLower = "legR.lower"
}

/// Canais extras que não são ângulos.
public enum PoseChannel: String, Sendable, CaseIterable {
    /// Deslocamento vertical do quadril, em pontos (agachar < 0).
    case rootDY = "root.dy"
    /// Squash & stretch: 1 = neutro, < 1 amassa, > 1 estica.
    case stretch
}

/// Proporções do corpo em pontos. O Glyph é pequeno: ~40 pt de altura.
public struct SkeletonMetrics: Sendable, Equatable {
    public var legUpper = 9.0
    public var legLower = 9.0
    public var torso = 13.0
    public var armUpper = 9.0
    public var armLower = 9.0
    public var headRadius = 6.0
    public var neck = 1.5
    /// Onde os braços saem, como fração do tronco a partir do quadril.
    public var shoulderAt = 0.85
    /// Distância de cada ombro ao eixo do tronco: os braços não saem do
    /// mesmo ponto, senão um braço levantado some atrás da cabeça.
    public var shoulderSpread = 2.5
    public var dotRadius = 2.6

    public init() {}

    public var height: Double { legUpper + legLower + torso + neck + headRadius * 2 }
    public var width: Double { 22 }
}

/// Um conjunto de valores por canal. Canais ausentes valem o repouso.
public struct Pose: Sendable, Equatable {
    public var values: [String: Double]

    public init(_ values: [String: Double] = [:]) { self.values = values }

    public subscript(_ j: Joint) -> Double {
        get { values[j.rawValue] ?? Pose.rest.values[j.rawValue] ?? 0 }
        set { values[j.rawValue] = newValue }
    }

    public subscript(_ c: PoseChannel) -> Double {
        get { values[c.rawValue] ?? (c == .stretch ? 1 : 0) }
        set { values[c.rawValue] = newValue }
    }

    /// Pose de repouso: braços levemente abertos, pernas levemente afastadas.
    public static let rest = Pose([
        Joint.torso.rawValue: 0,
        Joint.head.rawValue: 0,
        Joint.armLUpper.rawValue: 24,
        Joint.armLLower.rawValue: 8,
        Joint.armRUpper.rawValue: -24,
        Joint.armRLower.rawValue: -8,
        Joint.legLUpper.rawValue: 13,
        Joint.legLLower.rawValue: -6,
        Joint.legRUpper.rawValue: -13,
        Joint.legRLower.rawValue: 6,
    ])

    /// Sobrepõe `other`: canais presentes em `other` vencem.
    public func merging(_ other: Pose) -> Pose {
        Pose(values.merging(other.values) { _, b in b })
    }

    /// Soma aditiva de canais (camadas procedurais).
    public func adding(_ other: Pose) -> Pose {
        var out = self
        for (k, v) in other.values {
            if k == PoseChannel.stretch.rawValue {
                out.values[k] = (values[k] ?? 1) * v
            } else {
                out.values[k] = (values[k] ?? Pose.rest.values[k] ?? 0) + v
            }
        }
        return out
    }

    public static func lerp(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
        var out = Pose()
        for k in Set(a.values.keys).union(b.values.keys) {
            let neutral = k == PoseChannel.stretch.rawValue ? 1.0 : (Pose.rest.values[k] ?? 0)
            out.values[k] = Double.lerp(a.values[k] ?? neutral, b.values[k] ?? neutral, t)
        }
        return out
    }
}

/// Pontos do esqueleto já posicionados, em coordenadas locais:
/// origem entre os pés, no chão, y para cima.
public struct SkeletonPoints: Sendable, Equatable {
    public var hip: Vec2
    public var neck: Vec2
    public var shoulder: Vec2
    public var shoulderL: Vec2
    public var shoulderR: Vec2
    public var headCenter: Vec2
    public var headRadius: Double
    public var elbowL: Vec2
    public var handL: Vec2
    public var elbowR: Vec2
    public var handR: Vec2
    public var kneeL: Vec2
    public var footL: Vec2
    public var kneeR: Vec2
    public var footR: Vec2

    /// Traços a desenhar (polilinhas), sem a cabeça.
    public var strokes: [[Vec2]] {
        [
            [hip, neck],
            [shoulder, shoulderL, elbowL, handL],
            [shoulder, shoulderR, elbowR, handR],
            [hip, kneeL, footL],
            [hip, kneeR, footR],
        ]
    }

    public var allPoints: [Vec2] {
        [hip, neck, shoulder, shoulderL, shoulderR, headCenter, elbowL, handL, elbowR, handR, kneeL, footL, kneeR, footR]
    }

    public func mapped(_ f: (Vec2) -> Vec2) -> SkeletonPoints {
        SkeletonPoints(hip: f(hip), neck: f(neck), shoulder: f(shoulder), shoulderL: f(shoulderL),
                       shoulderR: f(shoulderR), headCenter: f(headCenter),
                       headRadius: headRadius, elbowL: f(elbowL), handL: f(handL), elbowR: f(elbowR),
                       handR: f(handR), kneeL: f(kneeL), footL: f(footL), kneeR: f(kneeR), footR: f(footR))
    }
}

public enum ForwardKinematics {
    /// Direção de um membro para um ângulo em graus (0 = para baixo, anti-horário).
    @inlinable
    public static func limbDirection(_ degrees: Double) -> Vec2 {
        let r = degrees.radians
        return Vec2(sin(r), -cos(r))
    }

    /// Calcula os pontos do esqueleto.
    /// - Parameter facing: +1 olhando para a direita (padrão), -1 espelhado.
    public static func solve(_ pose: Pose, metrics m: SkeletonMetrics = SkeletonMetrics(), facing: Double = 1) -> SkeletonPoints {
        let stretch = pose[.stretch].clamped(0.5, 1.6)
        // Squash & stretch preserva área: estica em y, amassa em x.
        let sx = 1 / stretch.squareRoot(), sy = stretch

        let legLen = m.legUpper + m.legLower
        let hip = Vec2(0, legLen + pose[.rootDY])

        let torsoDir = Vec2(-sin(pose[.torso].radians), cos(pose[.torso].radians))
        let neck = hip + torsoDir * m.torso
        let shoulder = hip + torsoDir * (m.torso * m.shoulderAt)
        let headDir = torsoDir.rotated(by: pose[.head].radians)
        let headCenter = neck + headDir * (m.neck + m.headRadius)

        func limb(_ root: Vec2, _ upper: Joint, _ lower: Joint, _ l1: Double, _ l2: Double) -> (Vec2, Vec2) {
            let a = pose[upper]
            let mid = root + limbDirection(a) * l1
            let end = mid + limbDirection(a + pose[lower]) * l2
            return (mid, end)
        }

        // Lado anatômico esquerdo fica à direita da tela (+x).
        let across = Vec2(torsoDir.y, -torsoDir.x) * m.shoulderSpread
        let shoulderL = shoulder + across, shoulderR = shoulder - across
        let (elbowL, handL) = limb(shoulderL, .armLUpper, .armLLower, m.armUpper, m.armLower)
        let (elbowR, handR) = limb(shoulderR, .armRUpper, .armRLower, m.armUpper, m.armLower)
        let (kneeL, footL) = limb(hip, .legLUpper, .legLLower, m.legUpper, m.legLower)
        let (kneeR, footR) = limb(hip, .legRUpper, .legRLower, m.legUpper, m.legLower)

        let raw = SkeletonPoints(hip: hip, neck: neck, shoulder: shoulder, shoulderL: shoulderL,
                                 shoulderR: shoulderR, headCenter: headCenter,
                                 headRadius: m.headRadius, elbowL: elbowL, handL: handL, elbowR: elbowR,
                                 handR: handR, kneeL: kneeL, footL: footL, kneeR: kneeR, footR: footR)
        let f = facing < 0 ? -1.0 : 1.0
        var out = raw.mapped { Vec2($0.x * sx * f, $0.y * sy) }
        out.headRadius = m.headRadius
        return out
    }
}
