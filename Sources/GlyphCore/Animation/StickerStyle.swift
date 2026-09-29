import Foundation

/// Regras visuais do estilo "adesivo recortado" (docs/ANIMATION.md).
public struct StickerStyle: Sendable, Equatable {
    /// Traço preto, pontas arredondadas.
    public var inkWidth = 2.5
    /// Contorno branco em volta do traço, por lado.
    public var outlineWidth = 3.0
    /// Sombra curta e suave.
    public var shadowOffset = Vec2(0, -1)
    public var shadowRadius = 2.0
    public var shadowOpacity = 0.25
    /// Amplitude do line boil, em pontos (±).
    public var boilAmplitude = 0.6
    /// O traço "ferve" a cada N quadros desenhados.
    public var boilEveryFrames = 3
    /// A física roda a 60 Hz; a pose é amostrada "em dois".
    public var physicsHz = 60.0
    public var poseFPS = 12.0

    public init() {}

    /// Largura total do traço branco que fica por baixo do preto.
    public var outlineStrokeWidth: Double { inkWidth + 2 * outlineWidth }

    public static let `default` = StickerStyle()
}

/// Deslocamento determinístico do traço desenhado à mão.
///
/// Mesmo `seed`, índice e balde de quadros → mesmo deslocamento. O balde
/// muda a cada `boilEveryFrames`, então o traço "ferve" sem tremer.
public struct LineBoil: Sendable {
    public var seed: UInt64
    public var style: StickerStyle

    public init(seed: UInt64 = 0x61_79_68_67, style: StickerStyle = .default) {
        self.seed = seed
        self.style = style
    }

    public func bucket(frame: Int) -> Int {
        frame / Swift.max(1, style.boilEveryFrames)
    }

    public func offset(pointIndex: Int, frame: Int) -> Vec2 {
        let b = UInt64(bitPattern: Int64(bucket(frame: frame)))
        var h = SplitMix64(seed: seed ^ (UInt64(bitPattern: Int64(pointIndex)) &* 0x9E37_79B9_7F4A_7C15) ^ (b &* 0xBF58_476D_1CE4_E5B9))
        let a = style.boilAmplitude
        return Vec2(h.nextUnit() * 2 * a - a, h.nextUnit() * 2 * a - a)
    }

    /// Aplica o boil a uma polilinha. `baseIndex` separa traços diferentes.
    public func apply(_ points: [Vec2], baseIndex: Int, frame: Int) -> [Vec2] {
        points.enumerated().map { i, p in p + offset(pointIndex: baseIndex + i, frame: frame) }
    }
}

/// Gerador pseudoaleatório pequeno e determinístico (SplitMix64).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Número em [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
