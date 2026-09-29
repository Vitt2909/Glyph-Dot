import Foundation

/// Estados de locomoção (a camada de baixo).
public enum Locomotion: String, Sendable, Equatable, CaseIterable {
    case stand, walk, run, jump, fall, land, climb, hang, carried
}

/// Intenção do corpo (a camada de cima), escolhida por utilidade.
public enum BodyIntent: Sendable, Equatable {
    case idle
    case wander(to: Double)
    case observe(Vec2)
    /// Ir até um ponto (janela relevante, cursor, pedido do cérebro).
    case approach(Vec2)
    case work(Vec2)
    case awaitApproval
    case sleep
    case home
    /// Janela cobrindo: correr para a borda antes de ser empurrado.
    case flee

    public var name: String {
        switch self {
        case .idle: return "idle"
        case .wander: return "wander"
        case .observe: return "observe"
        case .approach: return "approach"
        case .work: return "work"
        case .awaitApproval: return "awaitApproval"
        case .sleep: return "sleep"
        case .home: return "home"
        case .flee: return "flee"
        }
    }
}

/// Três necessidades simples que dão vida sem roteiro.
public struct Needs: Sendable, Equatable {
    /// Cai com o tempo e com trabalho. Baixa demais leva ao sono.
    public var energy = 1.0
    /// Sobe com eventos novos. Leva a observar e se aproximar.
    public var curiosity = 0.2
    /// Sobe com o cursor por perto. Leva a olhar, acenar, seguir.
    public var sociability = 0.2

    public init() {}

    /// Taxas por segundo.
    public struct Rates: Sendable, Equatable {
        /// Acordado e parado: ~45 min de 1 até 0.
        public var energyIdle = 1.0 / 2700
        public var energyMoving = 1.0 / 900
        public var energySleeping = 1.0 / 600
        public var curiosityDecay = 1.0 / 60
        public var sociabilityDecay = 1.0 / 45
        public var sociabilityNear = 1.0 / 8

        public init() {}
    }

    public mutating func update(dt: Double, moving: Bool, sleeping: Bool, cursorNear: Bool, rates: Rates = Rates()) {
        if sleeping {
            energy += rates.energySleeping * dt
        } else {
            energy -= (moving ? rates.energyMoving : rates.energyIdle) * dt
        }
        curiosity -= rates.curiosityDecay * dt
        sociability += (cursorNear ? rates.sociabilityNear : -rates.sociabilityDecay) * dt
        clamp()
    }

    public mutating func noticeEvent(novelty: Double) {
        curiosity += novelty
        clamp()
    }

    public mutating func clamp() {
        energy = energy.clamped(0, 1)
        curiosity = curiosity.clamped(0, 1)
        sociability = sociability.clamped(0, 1)
    }
}

/// Escolha por utilidade com histerese: a intenção atual ganha um bônus e só
/// perde depois de um tempo mínimo, para ele não ficar trocando de ideia.
public struct UtilityPicker: Sendable {
    public struct Option: Sendable {
        public var intent: BodyIntent
        public var score: Double
        /// Opções forçadas (fuga, pedido do cérebro, tela cheia) ignoram a histerese.
        public var forced: Bool

        public init(_ intent: BodyIntent, _ score: Double, forced: Bool = false) {
            self.intent = intent
            self.score = score
            self.forced = forced
        }
    }

    public var hysteresis = 0.12
    public var minDwell = 2.0
    public private(set) var current: BodyIntent = .idle
    public private(set) var heldFor = 0.0

    public init() {}

    /// Devolve a intenção escolhida e se ela mudou.
    @discardableResult
    public mutating func pick(_ options: [Option], dt: Double) -> (BodyIntent, changed: Bool) {
        heldFor += dt
        guard let best = options.max(by: { $0.score < $1.score }) else { return (current, false) }
        if best.intent.name == current.name {
            current = best.intent // atualiza parâmetros (alvo) sem "trocar"
            return (current, false)
        }
        let currentScore = options.first { $0.intent.name == current.name }?.score ?? 0
        let canSwitch = best.forced || (heldFor >= minDwell && best.score > currentScore + hysteresis)
        guard canSwitch else { return (current, false) }
        current = best.intent
        heldFor = 0
        return (current, true)
    }

    public mutating func force(_ intent: BodyIntent) {
        current = intent
        heldFor = 0
    }
}

/// Acompanha o cursor e classifica gestos.
public struct CursorTracker: Sendable {
    public struct Sample: Sendable, Equatable {
        public var time: Double
        public var position: Vec2
    }

    public private(set) var samples: [Sample] = []
    public var window = 0.12

    public init() {}

    public mutating func add(_ p: Vec2, at t: Double) {
        samples.append(Sample(time: t, position: p))
        samples.removeAll { t - $0.time > max(window, 0.5) }
    }

    public var position: Vec2? { samples.last?.position }

    /// Velocidade média nos últimos `window` segundos.
    public var velocity: Vec2 {
        guard let last = samples.last,
              let first = samples.last(where: { last.time - $0.time >= window }) ?? samples.first,
              last.time > first.time else { return .zero }
        return (last.position - first.position) / (last.time - first.time)
    }
}

/// Reação ao cursor (tabela em docs/ARCHITECTURE.md e no plano, seção 3.7).
public enum CursorReaction: Sendable, Equatable {
    case none
    /// Cursor se aproxima devagar: olha.
    case look(Vec2)
    /// Aproxima rápido: recua um passo, para longe do cursor.
    case recoil(dir: Double)
    /// Parado em cima dele por 1 s: acena.
    case wave
}

public struct CursorReactor: Sendable {
    public var nearDistance = 140.0
    public var fastSpeed = 900.0
    public var hoverTime = 1.0
    private var hoverStart: Double?
    private var waved = false
    private var lastRecoil = -10.0

    public init() {}

    /// - Parameters:
    ///   - body: centro do corpo; `hitbox`: caixa desenhada, em coordenadas globais.
    public mutating func react(cursor: CursorTracker, body: Vec2, hitbox: Rect, time: Double) -> CursorReaction {
        guard let p = cursor.position else { return .none }
        let d = p.distance(to: body)

        if hitbox.contains(p) {
            if hoverStart == nil { hoverStart = time }
            if !waved, let h = hoverStart, time - h >= hoverTime, cursor.velocity.length < 60 {
                waved = true
                return .wave
            }
            return .look(p)
        }
        hoverStart = nil
        waved = false

        guard d < nearDistance else { return .none }
        let v = cursor.velocity
        let toward = (body - p).normalized
        let approachSpeed = v.x * toward.x + v.y * toward.y
        if approachSpeed > fastSpeed, time - lastRecoil > 1.5 {
            lastRecoil = time
            return .recoil(dir: (body.x - p.x) >= 0 ? 1 : -1)
        }
        return .look(p)
    }
}
