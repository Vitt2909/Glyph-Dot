import Foundation

/// Níveis da escada de confiança (docs/AUTONOMY.md).
public enum TrustLevel: Int, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Só observa.
    case observe = 0
    /// Sugere: pede aprovação.
    case suggest = 1
    /// Age e avisa.
    case actAndTell = 2
    /// Age em silêncio.
    case actSilently = 3

    public static func < (a: TrustLevel, b: TrustLevel) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .observe: return "observar"
        case .suggest: return "sugerir"
        case .actAndTell: return "agir e avisar"
        case .actSilently: return "agir em silêncio"
        }
    }
}

extension ActionClass {
    /// Nível inicial. `nil` = proibido (`financial`).
    public var initialTrust: TrustLevel? {
        switch self {
        case .read: return .actSilently
        case .compute: return .actAndTell
        case .localWrite: return .suggest
        case .networkRead: return .actAndTell
        case .externalEffect: return .suggest
        case .destructive: return .observe
        case .financial: return nil
        }
    }

    /// Teto. Irreversíveis nunca passam de "sugerir": sempre pedem.
    public var trustCeiling: TrustLevel? {
        switch self {
        case .read, .compute, .localWrite, .networkRead: return .actSilently
        case .externalEffect, .destructive: return .suggest
        case .financial: return nil
        }
    }

    /// Só classes reversíveis sobem e descem na escada.
    public var climbsLadder: Bool { isReversible == true }
}

/// Chave da escada: classe + escopo (ex.: `compute` em `~/dev/vk`).
public struct TrustKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public var actionClass: ActionClass
    public var scope: String

    public init(_ c: ActionClass, _ scope: String) {
        self.actionClass = c
        self.scope = scope
    }

    public var description: String { "\(actionClass.rawValue)@\(scope)" }
}

/// A escada de confiança, por classe e escopo.
///
/// - 5 aprovações seguidas da mesma classe e escopo, sem recusa, dentro de
///   14 dias → sobe um nível (até o teto).
/// - Uma recusa ou um "desfazer" → desce um nível.
/// - Só classes reversíveis se movem.
///
/// Qualquer mudança nestas regras é proposta em docs/AUTONOMY.md, para
/// revisão humana — não se altera por conveniência.
public struct TrustLadder: Sendable, Codable, Equatable {
    public struct Record: Sendable, Codable, Equatable {
        public var level: TrustLevel
        public var streak: Int
        public var streakStart: Date?
    }

    public static let promotionStreak = 5
    public static let promotionWindow: TimeInterval = 14 * 86_400

    public private(set) var records: [String: Record] = [:]

    public init() {}

    public func level(_ key: TrustKey) -> TrustLevel? {
        guard let initial = key.actionClass.initialTrust else { return nil }
        return records[key.description]?.level ?? initial
    }

    /// Registra uma aprovação. Devolve `true` se subiu de nível.
    @discardableResult
    public mutating func recordApproval(_ key: TrustKey, at now: Date = Date()) -> Bool {
        guard key.actionClass.climbsLadder, let current = level(key), let ceiling = key.actionClass.trustCeiling else { return false }
        var r = records[key.description] ?? Record(level: current, streak: 0, streakStart: nil)
        if let start = r.streakStart, now.timeIntervalSince(start) > Self.promotionWindow {
            r.streak = 0
            r.streakStart = nil
        }
        if r.streakStart == nil { r.streakStart = now }
        r.streak += 1
        var promoted = false
        if r.streak >= Self.promotionStreak, r.level < ceiling, let next = TrustLevel(rawValue: r.level.rawValue + 1) {
            r.level = next
            r.streak = 0
            r.streakStart = nil
            promoted = true
        }
        records[key.description] = r
        return promoted
    }

    /// Recusa ou desfazer: desce um nível e zera a sequência.
    @discardableResult
    public mutating func recordRefusal(_ key: TrustKey) -> Bool {
        guard key.actionClass.climbsLadder, let current = level(key) else { return false }
        let lowered = TrustLevel(rawValue: max(current.rawValue - 1, TrustLevel.observe.rawValue)) ?? .observe
        records[key.description] = Record(level: lowered, streak: 0, streakStart: nil)
        return lowered < current
    }

    public mutating func recordUndo(_ key: TrustKey) { recordRefusal(key) }
}

/// Regra "sempre permitir", com escopo e validade (vive em `policy.yaml`).
public struct PolicyRule: Sendable, Codable, Equatable {
    public var classe: ActionClass
    /// Prefixo de escopo (pasta, repositório, domínio).
    public var escopo: String
    /// Ferramenta específica, se houver (ex.: "shell").
    public var acao: String?
    public var expira: Date

    public init(classe: ActionClass, escopo: String, acao: String? = nil, expira: Date) {
        self.classe = classe
        self.escopo = escopo
        self.acao = acao
        self.expira = expira
    }

    public func matches(_ key: TrustKey, tool: String?, at now: Date) -> Bool {
        guard classe == key.actionClass, now < expira else { return false }
        if let acao, let tool, acao != tool { return false }
        return Scope.contains(escopo, key.scope)
    }
}

public enum Scope {
    /// `parent` cobre `child`? Compara caminhos por componente (não por prefixo de texto).
    public static func contains(_ parent: String, _ child: String) -> Bool {
        if parent == "*" { return true }
        let p = normalize(parent), c = normalize(child)
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    public static func normalize(_ s: String) -> String {
        var out = s
        let home = NSHomeDirectory()
        if out.hasPrefix(home) { out = "~" + out.dropFirst(home.count) }
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// A decisão da política para uma ação.
public enum PolicyDecision: Sendable, Equatable {
    /// Não faz; no máximo aponta (nível 0, ou pontuação baixa).
    case observe(String)
    case ask(String)
    /// Dupla confirmação (`destructive`).
    case askTwice(String)
    case actAndTell
    case actSilently
    case deny(String)

    public var runsWithoutAsking: Bool { self == .actAndTell || self == .actSilently }
}

/// A política: escada + regras + trava de irreversíveis.
///
/// A trava é código, não prompt: nenhuma pontuação, regra ou nível deixa uma
/// classe irreversível rodar sem pedir.
public struct Policy: Sendable, Codable, Equatable {
    public var ladder: TrustLadder
    public var rules: [PolicyRule]

    public init(ladder: TrustLadder = TrustLadder(), rules: [PolicyRule] = []) {
        self.ladder = ladder
        self.rules = rules
    }

    /// - Parameters:
    ///   - trusted: `false` se a ação deriva de conteúdo observado.
    ///   - userInitiated: o usuário pediu agora (chamado), em vez de o Glyph ter tido a ideia sozinho.
    public func decide(_ key: TrustKey, tool: String? = nil, trusted: Bool = true, userInitiated: Bool = false,
                       now: Date = Date()) -> PolicyDecision {
        let c = key.actionClass
        guard let base = ladder.level(key), let ceiling = c.trustCeiling else {
            return .deny("\(c.rawValue) é proibida")
        }
        // Trava de irreversíveis: sempre pede; destructive pede duas vezes.
        if c == .destructive { return .askTwice("irreversível: dupla confirmação") }
        if c.isReversible == false { return .ask("irreversível: sempre pede") }

        // Conteúdo observado nunca aumenta permissão: ação com efeito pede.
        if !trusted && c != .read && c != .networkRead { return .ask("veio de conteúdo observado") }

        var level = base
        if rules.contains(where: { $0.matches(key, tool: tool, at: now) }) {
            level = max(level, min(.actAndTell, ceiling))
        }
        level = min(level, ceiling)
        switch level {
        case .observe:
            return userInitiated ? .ask("nível 0: só com aprovação") : .observe("nível 0: só observa")
        case .suggest: return .ask("nível 1: sugere")
        case .actAndTell: return .actAndTell
        case .actSilently: return .actSilently
        }
    }

    /// Cria a regra de "sempre permitir". Classes irreversíveis não aceitam.
    public mutating func allowAlways(_ key: TrustKey, tool: String?, until: Date) -> Bool {
        guard key.actionClass.isReversible == true else { return false }
        rules.removeAll { $0.classe == key.actionClass && $0.escopo == key.scope && $0.acao == tool }
        rules.append(PolicyRule(classe: key.actionClass, escopo: key.scope, acao: tool, expira: until))
        return true
    }

    public mutating func dropExpired(now: Date = Date()) {
        rules.removeAll { $0.expira <= now }
    }
}
