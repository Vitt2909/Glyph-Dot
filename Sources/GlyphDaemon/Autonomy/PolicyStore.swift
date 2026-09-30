import Foundation
import GlyphCore

/// Guarda a política na casa:
/// - `policy.yaml`: regras "sempre permitir" (legíveis e editáveis à mão);
/// - `confianca.json`: escada de confiança e calibração (estado interno).
public actor PolicyStore {
    public private(set) var policy: Policy
    public private(set) var calibrator: ConfidenceCalibrator
    private let policyURL: URL?
    private let trustURL: URL?

    public init(policyURL: URL?, trustURL: URL?) {
        self.policyURL = policyURL
        self.trustURL = trustURL
        var p = Policy()
        var cal = ConfidenceCalibrator()
        if let trustURL, let data = try? Data(contentsOf: trustURL),
           let saved = try? JSONDecoder.glyph.decode(TrustState.self, from: data) {
            p.ladder = saved.ladder
            cal = saved.calibrator
        }
        if let policyURL, let text = try? String(contentsOf: policyURL, encoding: .utf8) {
            p.rules = Self.parseRules(text)
        }
        p.dropExpired()
        policy = p
        calibrator = cal
    }

    struct TrustState: Codable {
        var ladder: TrustLadder
        var calibrator: ConfidenceCalibrator
    }

    public func decide(_ key: TrustKey, tool: String?, trusted: Bool, userInitiated: Bool) -> PolicyDecision {
        policy.decide(key, tool: tool, trusted: trusted, userInitiated: userInitiated)
    }

    public func authorization(_ key: TrustKey, tool: String?) -> Authorization {
        policy.authorization(key, tool: tool)
    }

    /// Registra aprovação ou recusa. Devolve a mudança de nível, se houve.
    @discardableResult
    public func record(_ key: TrustKey, approved: Bool) -> TrustLevel? {
        let before = policy.ladder.level(key)
        if approved { policy.ladder.recordApproval(key) } else { policy.ladder.recordRefusal(key) }
        save()
        let after = policy.ladder.level(key)
        return after != before ? after : nil
    }

    public func recordUndo(_ key: TrustKey) {
        policy.ladder.recordUndo(key)
        save()
    }

    public func recordOutcome(_ c: ActionClass, predicted: Double, success: Bool) {
        calibrator.record(c, predicted: predicted, success: success)
        save()
    }

    /// "Sempre permitir" vindo do cartão: regra com escopo e validade.
    @discardableResult
    public func allowAlways(_ key: TrustKey, tool: String?, until: Date) -> Bool {
        let ok = policy.allowAlways(key, tool: tool, until: until)
        if ok { save() }
        return ok
    }

    private func save() {
        if let trustURL, let data = try? JSONEncoder.glyph.encode(TrustState(ladder: policy.ladder, calibrator: calibrator)) {
            try? data.write(to: trustURL, options: .atomic)
        }
        if let policyURL {
            try? Self.renderRules(policy.rules).write(to: policyURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - policy.yaml

    static func parseRules(_ text: String) -> [PolicyRule] {
        guard let value = try? MiniYAML.parse(text), case let .array(items)? = value["regras"] else { return [] }
        return items.compactMap { item in
            guard let c = item["classe"]?.string.flatMap(ActionClass.init(rawValue:)),
                  let escopo = item["escopo"]?.string,
                  let expira = item["expira"]?.string.flatMap(ISO8601.parse) else { return nil }
            return PolicyRule(classe: c, escopo: escopo, acao: item["acao"]?.string, expira: expira)
        }
    }

    static func renderRules(_ rules: [PolicyRule]) -> String {
        var out = """
        # Regras "sempre permitir" criadas pelos cartões de aprovação.
        # Cada regra vale para uma classe de ação, num escopo, até uma data.
        # Classes irreversíveis (external_effect, destructive) não entram aqui:
        # elas sempre pedem.

        regras:

        """
        if rules.isEmpty { return out.replacingOccurrences(of: "regras:\n", with: "regras: []\n") }
        for r in rules {
            out += "  - classe: \(r.classe.rawValue)\n"
            out += "    escopo: \"\(r.escopo)\"\n"
            if let a = r.acao { out += "    acao: \(a)\n" }
            out += "    expira: \"\(ISO8601.format(r.expira))\"\n"
        }
        return out
    }
}

/// O portão do agente com a política de verdade (M3).
public struct PolicyGate: ActionGate {
    public let store: PolicyStore

    public init(store: PolicyStore) { self.store = store }

    public func decide(tool: String, actionClass: ActionClass, scope: String, trusted: Bool, userInitiated: Bool) async -> GateDecision {
        switch await store.decide(TrustKey(actionClass, scope), tool: tool, trusted: trusted, userInitiated: userInitiated) {
        case .actSilently: return .allow
        // Se o próprio usuário pediu, a resposta final já é o aviso: sem bolha extra.
        case .actAndTell: return userInitiated ? .allow : .allowAndAnnounce
        case .ask: return .ask
        case .askTwice: return .askTwice
        case let .observe(why): return .deny("só observando: \(why)")
        case let .deny(why): return .deny(why)
        }
    }

    public func feedback(tool: String, actionClass: ActionClass, scope: String, approved: Bool) async {
        await store.record(TrustKey(actionClass, scope), approved: approved)
    }
}

extension JSONEncoder {
    static var glyph: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601.format(d))
        }
        return e
    }
}

extension JSONDecoder {
    static var glyph: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "data inválida \(s)")
            }
            return date
        }
        return d
    }
}
