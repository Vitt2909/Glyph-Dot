import Foundation

// Glyph Protocol v0 — conteúdo de cada mensagem.
// A especificação completa está em docs/PROTOCOL.md.

/// Quem fala no socket. O papel é estabelecido pela autenticação do par
/// (UID + assinatura via audit token), nunca pelo conteúdo da mensagem.
public enum Peer: String, Sendable, Codable, CaseIterable {
    /// `Glyph.app`: desenha e percebe. Nunca executa.
    case body
    /// `glyphd` ou outro agente que fale o protocolo.
    case brain
}

/// Classes de ação (docs/AUTONOMY.md). A reversibilidade é propriedade da
/// classe, não da pontuação: nenhuma pontuação libera uma classe irreversível.
public enum ActionClass: String, Sendable, Codable, CaseIterable {
    case read
    case compute
    case localWrite = "local_write"
    case networkRead = "network_read"
    case externalEffect = "external_effect"
    case destructive
    case financial

    /// `nil` quando a pergunta não se aplica (leitura pura).
    public var isReversible: Bool? {
        switch self {
        case .read, .networkRead: return nil
        case .compute, .localWrite: return true
        case .externalEffect, .destructive, .financial: return false
        }
    }
}

public struct Hello: Sendable, Equatable, Codable {
    public var role: Peer
    /// Versões do protocolo que este par entende.
    public var protocolVersions: [Int]
    public var capabilities: [String]
    public var name: String?

    public init(role: Peer, protocolVersions: [Int] = [GlyphProtocol.version],
                capabilities: [String] = [], name: String? = nil) {
        self.role = role
        self.protocolVersions = protocolVersions
        self.capabilities = capabilities
        self.name = name
    }
}

/// Foco do usuário, usado como `F` na pontuação de intenções.
public enum UserFocus: String, Sendable, Codable {
    case normal
    case typing
    case fullscreen
    case meeting
}

/// Uma janela resumida para o cérebro: dono e posição. Nunca o título.
public struct WindowSummary: Sendable, Equatable, Codable {
    public var pid: Int32
    public var app: String
    public var frame: Rect

    public init(pid: Int32, app: String, frame: Rect) {
        self.pid = pid
        self.app = app
        self.frame = frame
    }
}

public struct WorldUpdate: Sendable, Equatable, Codable {
    public var activeApp: String?
    public var activePID: Int32?
    public var idleSeconds: Double
    public var cursorNearGlyph: Bool
    public var focus: UserFocus
    /// Janelas visíveis, da frente para trás (no máximo ~12).
    public var windows: [WindowSummary]?
    /// Onde o Glyph está (pés), para ele poder "voltar" depois de ir a uma janela.
    public var glyph: Vec2?

    public init(activeApp: String? = nil, activePID: Int32? = nil, idleSeconds: Double = 0,
                cursorNearGlyph: Bool = false, focus: UserFocus = .normal,
                windows: [WindowSummary]? = nil, glyph: Vec2? = nil) {
        self.activeApp = activeApp
        self.activePID = activePID
        self.idleSeconds = idleSeconds
        self.cursorNearGlyph = cursorNearGlyph
        self.focus = focus
        self.windows = windows
        self.glyph = glyph
    }
}

public struct InputSummon: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable { case hotkey, click, voice }
    public var source: Source
    public var text: String?

    public init(source: Source, text: String? = nil) {
        self.source = source
        self.text = text
    }
}

/// Freio global: pausa tudo, cancela tarefas, todos os Glyphs voltam para casa.
public struct InputBrake: Sendable, Equatable, Codable {
    /// `true` puxa o freio; `false` solta.
    public var engage: Bool

    public init(engage: Bool) { self.engage = engage }
}

public struct ApprovalResponse: Sendable, Equatable, Codable {
    public enum Decision: Sendable, Equatable {
        case approve
        case deny
        /// Cria uma regra com escopo e validade em policy.yaml, nunca uma
        /// preferência guardada na interface.
        case always(scope: String, expires: Date)
    }

    public var requestId: String
    public var decision: Decision

    public init(requestId: String, decision: Decision) {
        self.requestId = requestId
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case requestId, decision, scope, expires }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        switch try c.decode(String.self, forKey: .decision) {
        case "approve": decision = .approve
        case "deny": decision = .deny
        case "always":
            decision = .always(scope: try c.decode(String.self, forKey: .scope),
                               expires: try c.decode(Date.self, forKey: .expires))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .decision, in: c,
                                                   debugDescription: "decisão desconhecida: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        switch decision {
        case .approve: try c.encode("approve", forKey: .decision)
        case .deny: try c.encode("deny", forKey: .decision)
        case let .always(scope, expires):
            try c.encode("always", forKey: .decision)
            try c.encode(scope, forKey: .scope)
            try c.encode(expires, forKey: .expires)
        }
    }
}

public struct BodyGoto: Sendable, Equatable, Codable {
    public enum Target: Sendable, Equatable {
        case window(pid: Int32, frame: Rect)
        case point(Vec2)
        case home
    }

    public var target: Target

    public init(target: Target) { self.target = target }

    enum CodingKeys: String, CodingKey { case target, pid, frame, point }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .target) {
        case "window":
            target = .window(pid: try c.decode(Int32.self, forKey: .pid),
                             frame: try c.decode(Rect.self, forKey: .frame))
        case "point":
            target = .point(try c.decode(Vec2.self, forKey: .point))
        case "home":
            target = .home
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .target, in: c,
                                                   debugDescription: "alvo desconhecido: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case let .window(pid, frame):
            try c.encode("window", forKey: .target)
            try c.encode(pid, forKey: .pid)
            try c.encode(frame, forKey: .frame)
        case let .point(p):
            try c.encode("point", forKey: .target)
            try c.encode(p, forKey: .point)
        case .home:
            try c.encode("home", forKey: .target)
        }
    }
}

/// Como o Dot se comporta. O Dot muda de comportamento, não de cor.
public enum DotMode: String, Sendable, Codable, CaseIterable {
    case steady      // repouso: brilho estável, respira
    case glance      // observando: pequenos deslocamentos na direção do evento
    case orbit       // pensando: sai da cabeça e orbita
    case trail       // trabalhando: rastro de pontos até o alvo
    case blink       // esperando aprovação: pisca 2× e para
    case alert       // perigo: `!` acima da cabeça
    case shrink      // erro: encolhe um pouco
    case fade        // dormindo: esmaece
    case split       // multi-Glyph: um ponto se separa
    case pulse       // genérico, usado por clipes
}

public struct BodyEmote: Sendable, Equatable, Codable {
    public var clip: String
    public var dot: DotMode?
    /// Sticker do pack para segurar durante a emoção (ex.: "folha" ao salvar memória).
    public var sticker: String?
    /// Especialista (multi-Glyph) em vez do Glyph principal.
    public var agentId: String?

    public init(clip: String, dot: DotMode? = nil, sticker: String? = nil, agentId: String? = nil) {
        self.clip = clip
        self.dot = dot
        self.sticker = sticker
        self.agentId = agentId
    }
}

public struct BubbleSay: Sendable, Equatable, Codable {
    /// Bolhas têm no máximo ~40 caracteres. Apontar é preferível a falar.
    public static let maxLength = 40
    public static let defaultDuration = 4.0

    public var text: String
    public var durationSec: Double
    /// Quem fala: um especialista (id do `agent.spawn`, ou só o papel, ex.
    /// "auditor"). `nil` = o Glyph principal.
    public var agentId: String?

    public init(text: String, durationSec: Double = BubbleSay.defaultDuration, agentId: String? = nil) {
        self.text = text
        self.durationSec = durationSec
        self.agentId = agentId
    }

    /// Texto que o corpo realmente mostra: cortado em `maxLength` com reticências.
    public var displayText: String {
        guard text.count > Self.maxLength else { return text }
        return String(text.prefix(Self.maxLength - 1)) + "…"
    }
}

public struct ApprovalRequest: Sendable, Equatable, Codable {
    public var action: String
    public var target: String
    public var actionClass: ActionClass
    /// Motivo em uma linha.
    public var why: String
    /// Sem resposta até o timeout → negar.
    public var timeoutSec: Double

    public init(action: String, target: String, actionClass: ActionClass, why: String, timeoutSec: Double = 120) {
        self.action = action
        self.target = target
        self.actionClass = actionClass
        self.why = why
        self.timeoutSec = timeoutSec
    }

    enum CodingKeys: String, CodingKey {
        case action, target, actionClass = "class", why, timeoutSec
    }
}

public struct TaskUpdate: Sendable, Equatable, Codable {
    public var taskId: String
    public var step: String
    public var progress: Double
    /// Ações restantes no orçamento; o corpo mostra como pontos carregados.
    public var budgetRemaining: Int?

    public init(taskId: String, step: String, progress: Double, budgetRemaining: Int? = nil) {
        self.taskId = taskId
        self.step = step
        self.progress = progress
        self.budgetRemaining = budgetRemaining
    }
}

public enum SpecialistRole: String, Sendable, Codable, CaseIterable {
    case builder, researcher, designer, auditor
}

public struct AgentSpawn: Sendable, Equatable, Codable {
    public var agentId: String
    public var role: SpecialistRole

    public init(agentId: String, role: SpecialistRole) {
        self.agentId = agentId
        self.role = role
    }
}

public struct AgentDespawn: Sendable, Equatable, Codable {
    public var agentId: String

    public init(agentId: String) { self.agentId = agentId }
}

public struct DiaryReady: Sendable, Equatable, Codable {
    public var path: String

    public init(path: String) { self.path = path }
}
