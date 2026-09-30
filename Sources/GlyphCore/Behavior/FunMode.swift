import Foundation

// Modo Diversão (docs/DIVERSAO.md): por alguns minutos o desktop vira palco.
//
// Tudo aqui é só encenação. O corpo não executa nada, o comando não vai ao
// cérebro e qualquer sinal de verdade (freio, aprovação, alerta, tarefa)
// encerra a brincadeira na hora, sem tentar terminar a cena.

/// Um comando do Modo Diversão, digitado no campo de chamada.
public enum FunCommand: String, Sendable, Equatable, CaseIterable {
    case start, stop, surprise, dance, robot, trick, statue, stage

    /// Aceita a forma com barra (`/danca`) e algumas frases naturais
    /// ("dança pra mim"). Maiúsculas, acentos, espaços extras e pontuação
    /// final não importam. Qualquer outro texto devolve `nil` e segue para o
    /// cérebro como sempre.
    public static func parse(_ text: String) -> FunCommand? {
        phrases[normalize(text)]
    }

    static let phrases: [String: FunCommand] = {
        let table: [FunCommand: [String]] = [
            .start: ["/diversao", "/diversao iniciar", "vamos brincar", "vamos brincar por cinco minutos",
                     "vamos brincar por 5 minutos", "bora brincar"],
            .stop: ["/diversao parar", "chega de brincar", "para de brincar", "parar de brincar"],
            .surprise: ["/surpresa", "me surpreenda", "surpreenda-me"],
            .dance: ["/danca", "danca", "danca pra mim", "danca para mim"],
            .robot: ["/robo", "modo robo"],
            .trick: ["/truque", "mostra um truque", "mostra um truque com o dot", "faz um truque"],
            .statue: ["/estatua", "estatua", "brincar de estatua", "vamos brincar de estatua"],
            .stage: ["/janela-palco", "/palco", "sobe no palco", "faz um show na janela"],
        ]
        var out: [String: FunCommand] = [:]
        for (command, list) in table { for p in list { out[p] = command } }
        return out
    }()

    static let plain: [Character: Character] = [
        "á": "a", "à": "a", "â": "a", "ã": "a", "ä": "a", "é": "e", "è": "e", "ê": "e", "í": "i", "ì": "i",
        "ó": "o", "ò": "o", "ô": "o", "õ": "o", "ö": "o", "ú": "u", "ù": "u", "ü": "u", "ç": "c",
    ]

    /// Minúsculas, sem acento, espaços simples, sem pontuação no fim.
    static func normalize(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in text.lowercased() {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            if let p = plain[ch] {
                out.append(p)
            } else {
                // Acento combinante (a + ◌́): fica só a letra.
                let scalars = ch.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
                out.unicodeScalars.append(contentsOf: scalars)
            }
        }
        while let last = out.last, "!.?…".contains(last) || last == " " { out.removeLast() }
        return out
    }
}

/// Uma batida de uma cena: um gesto, um trajeto ou o jogo da estátua.
public struct FunBeat: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Faz o clipe no lugar por `duration` segundos.
        case pose
        /// Anda até o ponto com a navegação e a física de verdade; `clip`
        /// troca o andar. `duration` é o prazo para chegar.
        case go(Vec2)
        /// Segura a pose até o clique, o riso ou o fim de `duration`.
        case statue
    }

    public var action: Action
    public var clip: String
    public var duration: Double
    /// Modo do Dot; `nil` usa o do clipe.
    public var dot: DotMode?
    /// Bolha curta no início da batida.
    public var bubble: String?
    /// Voltas completas (trocando de lado) durante a batida: o giro.
    public var turns: Int
    /// Riso contido: a pose treme um pouco.
    public var shake: Bool

    public init(_ action: Action = .pose, clip: String, duration: Double, dot: DotMode? = nil,
                bubble: String? = nil, turns: Int = 0, shake: Bool = false) {
        self.action = action
        self.clip = clip
        self.duration = duration
        self.dot = dot
        self.bubble = bubble
        self.turns = turns
        self.shake = shake
    }

    public static func pose(_ clip: String, _ duration: Double, bubble: String? = nil, turns: Int = 0,
                            shake: Bool = false) -> FunBeat {
        FunBeat(.pose, clip: clip, duration: duration, bubble: bubble, turns: turns, shake: shake)
    }

    public var isGo: Bool {
        if case .go = action { return true }
        return false
    }
}

/// Uma apresentação finita: começo, ação e saída.
public struct FunScene: Sendable, Equatable {
    public var command: FunCommand
    public var beats: [FunBeat]

    public init(command: FunCommand, beats: [FunBeat]) {
        self.command = command
        self.beats = beats
    }

    /// Duração sem contar trajetos (que dependem do caminho).
    public var poseDuration: Double { beats.filter { !$0.isGo }.reduce(0) { $0 + $1.duration } }
}

/// O trecho de borda de janela usado em `/janela-palco`.
public struct FunStage: Sendable, Equatable {
    public var entry: Vec2
    public var exit: Vec2

    public static let minLength = 120.0
    public static let maxWalk = 240.0

    /// A borda de janela visível mais próxima com espaço para desfilar.
    /// Sem nenhuma, `nil`: o Glyph propõe outra brincadeira.
    public static func find(in world: World, near p: Vec2, inset: Double = 24) -> FunStage? {
        let tops = world.standable.filter { $0.kind.windowID != nil && $0.length >= minLength }
        let best = tops.min { a, b in
            Vec2(a.clampX(p.x), a.y).distance(to: p) < Vec2(b.clampX(p.x), b.y).distance(to: p)
        }
        guard let s = best else { return nil }
        if p.x <= s.midX {
            let entry = s.x0 + inset
            return FunStage(entry: Vec2(entry, s.y), exit: Vec2(min(s.x1 - inset, entry + maxWalk), s.y))
        }
        let entry = s.x1 - inset
        return FunStage(entry: Vec2(entry, s.y), exit: Vec2(max(s.x0 + inset, entry - maxWalk), s.y))
    }
}

/// As cenas da primeira versão.
public enum FunCatalog {
    /// O que `/surpresa` pode sortear. A estátua é jogo, não cena.
    public static let surprises: [FunCommand] = [.dance, .robot, .trick, .stage]

    /// A cena de um comando, ou `nil` se faltar clipe ou geometria.
    /// `stop` e `surprise` não têm cena própria.
    public static func scene(for command: FunCommand, clips: ClipLibrary, stage: FunStage? = nil,
                             reducedMotion: Bool = false) -> FunScene? {
        var beats: [FunBeat]
        switch command {
        case .stop, .surprise:
            return nil
        case .start:
            beats = [.pose("invite", 1.6, bubble: "bora brincar? tenta /danca")]
        case .dance:
            if clips["danca"] != nil {
                // O pack de exemplo instalado: usa a dança dele.
                beats = [.pose("danca", 5), .pose("ta-da", 1.2)]
            } else {
                beats = [.pose("groove", 3.2), .pose("spin", 1, turns: 2), .pose("groove", 2), .pose("ta-da", 1.2)]
            }
        case .robot:
            beats = [.pose("robot", 3.7, bubble: "bip. bop.")]
        case .trick:
            beats = [.pose("dot-juggle", 3, bubble: "olha o Dot!"), .pose("ta-da", 1.2, bubble: "ta-da!")]
        case .statue:
            beats = [FunBeat(.statue, clip: "statue", duration: FunMode.statueRound, bubble: "estátua! tenta me fazer rir.")]
        case .stage:
            if reducedMotion {
                beats = [.pose("bow", 1.1, bubble: "obrigado!")]
            } else {
                guard let stage else { return nil }
                let walk = clips["parade"] != nil ? "parade" : "walk"
                beats = [
                    FunBeat(.go(stage.entry), clip: walk, duration: 12, bubble: "subindo no palco!"),
                    FunBeat(.go(stage.exit), clip: walk, duration: 12),
                    .pose("balance", 1.4),
                    .pose("spin", 0.9, turns: 1),
                    .pose("bow", 1.1, bubble: "obrigado!"),
                ]
            }
        }
        if reducedMotion, command != .statue, var last = beats.last(where: { !$0.isGo }) {
            // Movimento reduzido: só a pose final, sem giro, com a primeira fala.
            last.turns = 0
            last.bubble = last.bubble ?? beats.compactMap(\.bubble).first
            beats = [last]
        }
        guard beats.allSatisfy({ clips[$0.clip] != nil }) else { return nil }
        return FunScene(command: command, beats: beats)
    }

    /// Fim da estátua: o cursor fez ele rir.
    public static let statueLost = FunScene(command: .statue, beats: [
        .pose("idle", 1, bubble: "hahaha! perdi.", shake: true), .pose("bow", 1.1),
    ])
    /// Fim da estátua: aguentou a rodada inteira.
    public static let statueWon = FunScene(command: .statue, beats: [.pose("ta-da", 1.2, bubble: "ganhei!")])
    /// Fim da estátua: o usuário clicou nele.
    public static let statueClicked = FunScene(command: .statue, beats: [.pose("wave", 0.8, bubble: "valeu!")])
}

/// Estado do Modo Diversão: ligado ou não, e a cena em curso.
public struct FunMode: Sendable, Equatable {
    /// `/diversao iniciar` liga por 5 minutos.
    public static let sessionLength = 300.0
    /// Uma rodada de estátua dura até 30 s.
    public static let statueRound = 30.0
    /// Quantas vezes o cursor chega perto antes de ele rir.
    public static let statueLives = 3
    /// Distância (pt) do cursor ao centro do corpo que conta como provocação.
    public static let tickleNear = 70.0
    public static let tickleFar = 110.0

    public private(set) var until: Double?
    public private(set) var scene: FunScene?
    public private(set) var beat = 0
    public private(set) var beatStart = 0.0
    /// A batida só começa com o Glyph de pé, fora de casa.
    public private(set) var begun = false
    public private(set) var lastShow: FunCommand?
    public private(set) var giggles = 0
    public private(set) var lastGiggle = -10.0
    private var cursorClose = false

    public init() {}

    public var isOn: Bool { until != nil }
    public var current: FunBeat? { scene.flatMap { beat < $0.beats.count ? $0.beats[beat] : nil } }

    public mutating func begin(at t: Double) {
        until = t + Self.sessionLength
    }

    /// Desliga o modo e corta a cena.
    public mutating func end() {
        until = nil
        cancelShow()
    }

    public mutating func cancelShow() {
        scene = nil
        beat = 0
        begun = false
    }

    public mutating func play(_ s: FunScene, at t: Double) {
        scene = s
        beat = 0
        beatStart = t
        begun = false
        giggles = 0
        cursorClose = false
        lastGiggle = -10
        if FunCatalog.surprises.contains(s.command) { lastShow = s.command }
    }

    /// Ainda esperando o Glyph ficar pronto: o relógio da batida não anda.
    public mutating func hold(at t: Double) {
        beatStart = t
    }

    public mutating func markBegun(at t: Double) {
        begun = true
        beatStart = t
    }

    public mutating func next(at t: Double) {
        beat += 1
        beatStart = t
        begun = false
        if current == nil { cancelShow() }
    }

    /// Sorteia uma cena sem repetir a última.
    public mutating func pickSurprise(from options: [FunCommand], rng: inout SplitMix64) -> FunCommand? {
        let fresh = options.filter { $0 != lastShow }
        let pool = fresh.isEmpty ? options : fresh
        guard !pool.isEmpty else { return nil }
        return pool[min(Int(rng.nextUnit() * Double(pool.count)), pool.count - 1)]
    }

    /// Estátua: o cursor chegou perto? Cada aproximação nova (com folga
    /// entre elas) quase faz ele rir.
    public mutating func cursor(distance d: Double, at t: Double) {
        if d < Self.tickleNear, !cursorClose {
            cursorClose = true
            if t - lastGiggle > 0.8 {
                giggles += 1
                lastGiggle = t
            }
        } else if d > Self.tickleFar {
            cursorClose = false
        }
    }

    /// A pose deve tremer agora (riso contido ou quase-riso da estátua)?
    public func shaking(at t: Double) -> Bool {
        guard let b = current, begun else { return false }
        return b.shake || (b.action == .statue && t - lastGiggle < 0.4)
    }

    /// Lado desenhado durante um giro: troca a cada meia-volta e termina no
    /// lado em que começou.
    public func flipped(at t: Double) -> Bool {
        guard let b = current, begun, b.turns > 0, b.duration > 0 else { return false }
        let half = b.duration / Double(b.turns * 2)
        let i = Int((t - beatStart) / half)
        return i < b.turns * 2 && i % 2 == 1
    }
}
