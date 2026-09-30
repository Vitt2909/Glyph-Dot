import Foundation

// "Por que você fez isso?" (proposta 0002, ideia 8).
//
// A explicação é montada a partir do que foi registrado na hora da ação, por
// um texto fixo, sem chamar o cérebro. Uma explicação gerada depois por um
// modelo seria uma racionalização, não um registro.

/// O que permitiu (ou impediu) a ação, no momento em que ela aconteceu.
public struct Authorization: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// Você pediu agora (campo de chamada, comando).
        case request = "pedido"
        /// A escada de confiança estava num nível que age sem pedir.
        case ladder = "escada"
        /// Uma regra "sempre permitir" com escopo e validade.
        case rule = "regra"
        /// Você aprovou num cartão.
        case card = "cartao"
        /// Um objetivo seu autoriza a classe dentro do espaço da tarefa.
        case goal = "objetivo"
        /// Você aprovou um plano de ensaio.
        case plan = "plano"
        /// Você recusou, ou o cartão expirou.
        case refused = "recusado"
        /// A política não deixou (nível 0, classe proibida, conteúdo observado).
        case policy = "politica"
    }

    public var kind: Kind
    public var level: Int?
    public var actionClass: ActionClass?
    public var scope: String?
    /// Fim da regra "sempre" (ISO 8601).
    public var until: String?
    /// Quando você respondeu ao cartão (ISO 8601).
    public var at: String?
    /// Objetivo ou plano.
    public var ref: String?
    public var note: String?

    public init(_ kind: Kind, level: Int? = nil, actionClass: ActionClass? = nil, scope: String? = nil,
                until: Date? = nil, at: Date? = nil, ref: String? = nil, note: String? = nil) {
        self.kind = kind
        self.level = level
        self.actionClass = actionClass
        self.scope = scope
        self.until = until.map(ISO8601.format)
        self.at = at.map(ISO8601.format)
        self.ref = ref
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case kind, level, actionClass = "class", scope, until, at, ref, note
    }
}

/// Quanto custou.
public struct ActionCost: Sendable, Codable, Equatable {
    public var tokens: Int?
    public var usd: Double?
    public var seconds: Double?

    public init(tokens: Int? = nil, usd: Double? = nil, seconds: Double? = nil) {
        self.tokens = tokens
        self.usd = usd
        self.seconds = seconds
    }

    public var isEmpty: Bool { (tokens ?? 0) == 0 && (usd ?? 0) == 0 && seconds == nil }
}

/// O mínimo de uma entrada do histórico para explicá-la. Decodifica uma linha
/// de `historico.jsonl` diretamente (o corpo usa assim, sem o `glyphd`).
public struct WhyRecord: Sendable, Codable, Equatable {
    public var id: String?
    public var origin: String?
    public var summary: String
    public var outcome: String?
    public var detail: String?
    public var actionClass: ActionClass?
    public var scope: String?
    public var tool: String?
    public var trigger: String?
    public var authorization: Authorization?
    public var cost: ActionCost?
    public var evidence: String?
    public var undoable: Bool

    public init(id: String? = nil, origin: String? = nil, summary: String, outcome: String? = nil, detail: String? = nil,
                actionClass: ActionClass? = nil, scope: String? = nil, tool: String? = nil, trigger: String? = nil,
                authorization: Authorization? = nil, cost: ActionCost? = nil, evidence: String? = nil,
                undoable: Bool = false) {
        self.id = id
        self.origin = origin
        self.summary = summary
        self.outcome = outcome
        self.detail = detail
        self.actionClass = actionClass
        self.scope = scope
        self.tool = tool
        self.trigger = trigger
        self.authorization = authorization
        self.cost = cost
        self.evidence = evidence
        self.undoable = undoable
    }

    enum CodingKeys: String, CodingKey {
        case id, origin, summary, outcome, detail, actionClass, scope, tool, trigger, authorization, cost, evidence, inverse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        actionClass = try? c.decodeIfPresent(ActionClass.self, forKey: .actionClass)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        authorization = try? c.decodeIfPresent(Authorization.self, forKey: .authorization)
        cost = try? c.decodeIfPresent(ActionCost.self, forKey: .cost)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        undoable = c.contains(.inverse) && (try? c.decodeNil(forKey: .inverse)) == false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(actionClass, forKey: .actionClass)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(trigger, forKey: .trigger)
        try c.encodeIfPresent(authorization, forKey: .authorization)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(evidence, forKey: .evidence)
    }
}

/// Monta a explicação. Só texto fixo sobre campos registrados.
public enum Explanation {
    /// Várias linhas, para `glyphd porque` e a casa.
    public static func lines(_ r: WhyRecord) -> [String] {
        var out: [String] = []
        let autonomous = r.origin == "autonomous"

        if let t = r.trigger, !t.isEmpty {
            out.append("Percebi: \(t).")
        } else if !autonomous {
            out.append("Você pediu: \(quote(r.summary)).")
        }

        switch r.outcome {
        case "done": out.append(autonomous ? "Fiz: \(r.summary)." : "Fiz o que você pediu\(r.tool.map { " (\($0))" } ?? "").")
        case "failed": out.append("Tentei, mas falhou: \(r.summary).")
        case "denied": out.append("Não fiz: \(r.summary).")
        case "observed": out.append("Só observei: \(r.summary).")
        case "noted": out.append("Só apontei: \(r.summary). Não valia interromper você.")
        case "discarded": out.append("Deixei para lá: \(r.summary).")
        case "undone": out.append("Desfiz: \(r.summary).")
        default: out.append(r.summary + ".")
        }

        if let a = r.authorization { out.append(authorizationLine(a)) }

        if let d = r.detail, !d.isEmpty {
            out.append("Resultado: \(oneLine(d)).")
        }
        if let e = r.evidence, !e.isEmpty {
            out.append("Evidência: \(oneLine(e)).")
        }
        if let c = r.cost, !c.isEmpty {
            out.append("Custo: \(costText(c)).")
        }
        if r.undoable, let id = r.id {
            out.append("Dá para desfazer: glyphd desfazer \(id)")
        }
        return out
    }

    /// Uma frase curta para a bolha (clique no Glyph logo depois de agir).
    public static func short(_ r: WhyRecord) -> String {
        var s = ""
        if let t = r.trigger, !t.isEmpty { s = "percebi \(t). " }
        if let a = r.authorization {
            switch a.kind {
            case .ladder: s += "fiz sem pedir: tenho nível \(a.level ?? 0) para \(a.actionClass?.rawValue ?? "isso") aqui."
            case .rule: s += "fiz sem pedir: você disse \"sempre\" para isso."
            case .card: s += "fiz porque você aprovou."
            case .goal: s += "fiz pelo objetivo \(a.ref ?? "")."
            case .plan: s += "fiz pelo plano que você aprovou."
            case .request: s += "fiz porque você pediu."
            case .refused: s += "não fiz: você não aprovou."
            case .policy: s += "não fiz: \(a.note ?? "a política não deixou")."
            }
        } else {
            s += r.summary
        }
        return s
    }

    public static func authorizationLine(_ a: Authorization) -> String {
        let cls = a.actionClass?.rawValue ?? "esta classe"
        let scope = a.scope.map { " em \(shortPath($0))" } ?? ""
        switch a.kind {
        case .request:
            return "Pude porque você pediu agora."
        case .ladder:
            let lvl = a.level ?? 0
            return lvl >= 2
                ? "Pude sem pedir: a escada está no nível \(lvl) para \(cls)\(scope)."
                : "A escada está no nível \(lvl) para \(cls)\(scope): \(lvl == 0 ? "só observo" : "só sugiro")."
        case .rule:
            return "Pude sem pedir: regra \"sempre\" para \(cls)\(scope)\(a.until.map { ", até \(day($0))" } ?? "")."
        case .card:
            return "Você aprovou no cartão\(a.at.map { " às \(time($0))" } ?? "")."
        case .goal:
            return "O objetivo \(a.ref ?? "?") autoriza \(cls) dentro do espaço da tarefa\(scope)."
        case .plan:
            return "Fazia parte do plano \(a.ref ?? "") que você aprovou\(a.at.map { " às \(time($0))" } ?? "")."
        case .refused:
            return "Não foi aprovado\(a.note.map { " (\($0))" } ?? " (recusa ou tempo esgotado)")."
        case .policy:
            return "A política não deixou: \(a.note ?? cls)."
        }
    }

    public static func costText(_ c: ActionCost) -> String {
        var parts: [String] = []
        if let t = c.tokens, t > 0 { parts.append("\(t) tokens") }
        if let u = c.usd, u > 0 { parts.append(String(format: "US$ %.4f", u)) }
        if let s = c.seconds { parts.append(s < 10 ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s") }
        return parts.joined(separator: " · ")
    }

    static func quote(_ s: String) -> String { "\"\(oneLine(s))\"" }

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = flat.hasSuffix(".") ? String(flat.dropLast()) : flat
        return trimmed.count > 160 ? String(trimmed.prefix(157)) + "…" : trimmed
    }

    /// `~/…` em vez da pasta pessoal inteira.
    public static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        if !home.isEmpty, home != "/", p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }

    static func time(_ iso: String) -> String {
        guard let d = ISO8601.parse(iso) else { return iso }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func day(_ iso: String) -> String {
        guard let d = ISO8601.parse(iso) else { return iso }
        let c = Calendar.current.dateComponents([.day, .month], from: d)
        return String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
    }
}
