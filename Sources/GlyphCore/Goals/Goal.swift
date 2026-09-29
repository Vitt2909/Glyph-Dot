import Foundation

/// Um objetivo permanente (`casa/goals.yaml`).
///
/// Objetivo só nasce de ação do usuário: este arquivo é escrito por ele (ou
/// pelo `glyphd objetivo`). Nada observado cria objetivo.
public struct Goal: Sendable, Equatable, Decodable, Identifiable {
    public struct DailyBudget: Sendable, Equatable, Decodable {
        public var acoes: Int?
        public var tokens: Int?
        public var usd: Double?

        public init(acoes: Int? = nil, tokens: Int? = nil, usd: Double? = nil) {
            self.acoes = acoes
            self.tokens = tokens
            self.usd = usd
        }
    }

    public var id: String
    public var descricao: String
    public var escopo: String?
    public var gatilhos: [String]?
    /// Comando que diz se o objetivo está cumprido (código de saída 0).
    public var sucesso: String?
    public var classes_permitidas: [ActionClass]?
    public var orcamento_diario: DailyBudget?
    /// "sempre", "noite" ou "HH:MM".
    public var horario: String?

    public init(id: String, descricao: String, escopo: String? = nil, gatilhos: [String]? = nil, sucesso: String? = nil,
                classes_permitidas: [ActionClass]? = nil, orcamento_diario: DailyBudget? = nil, horario: String? = nil) {
        self.id = id
        self.descricao = descricao
        self.escopo = escopo
        self.gatilhos = gatilhos
        self.sucesso = sucesso
        self.classes_permitidas = classes_permitidas
        self.orcamento_diario = orcamento_diario
        self.horario = horario
    }

    public var schedule: Schedule { Schedule(horario ?? "sempre") }

    public var allowedClasses: Set<ActionClass> { Set(classes_permitidas ?? [.read]) }

    /// Classes que o objetivo autoriza a rodar sem pedir, dentro do seu worktree.
    /// Nunca inclui irreversíveis, mesmo se o arquivo pedir.
    public var autonomousClasses: Set<ActionClass> {
        allowedClasses.filter { $0.isReversible != false }
    }

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case badID(String)
        case irreversibleClass(String, ActionClass)
        case badSchedule(String, String)
        case unsafeSuccess(String, String)

        public var description: String {
            switch self {
            case let .badID(id): return "id inválido: \(id)"
            case let .irreversibleClass(id, c): return "\(id): \(c.rawValue) não pode ser permitida (irreversível: sempre pede)"
            case let .badSchedule(id, h): return "\(id): horário inválido \(h) (use sempre, noite ou HH:MM)"
            case let .unsafeSuccess(id, why): return "\(id): comando de sucesso recusado (\(why))"
            }
        }
    }

    public func validate() throws {
        guard !id.isEmpty, id.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw ValidationError.badID(id)
        }
        for c in allowedClasses where c.isReversible == false {
            throw ValidationError.irreversibleClass(id, c)
        }
        if case .invalid = schedule { throw ValidationError.badSchedule(id, horario ?? "") }
        if let s = sucesso {
            let v = CommandClassifier.classify(s)
            if v.forbidden || v.actionClass == .destructive || v.actionClass == .financial {
                throw ValidationError.unsafeSuccess(id, v.reason)
            }
        }
    }

    /// Lê e valida `goals.yaml`. Objetivos inválidos voltam como erro, sem derrubar os outros.
    public static func load(yaml: String) -> (goals: [Goal], errors: [String]) {
        guard let value = try? MiniYAML.parse(yaml) else { return ([], ["goals.yaml ilegível"]) }
        guard case let .array(items) = value else { return value == .null ? ([], []) : ([], ["goals.yaml precisa ser uma lista"]) }
        var goals: [Goal] = []
        var errors: [String] = []
        for (i, item) in items.enumerated() {
            do {
                let data = try JSONSerialization.data(withJSONObject: item.jsonObject)
                let g = try JSONDecoder().decode(Goal.self, from: data)
                try g.validate()
                goals.append(g)
            } catch {
                errors.append("objetivo \(i + 1): \(error)")
            }
        }
        return (goals, errors)
    }
}

/// Quando um objetivo roda.
public enum Schedule: Sendable, Equatable {
    /// Por gatilho, a qualquer hora.
    case always
    /// Só à noite (22h–7h) ou com o usuário longe.
    case night
    /// Uma vez por dia, a partir deste horário.
    case daily(hour: Int, minute: Int)
    case invalid

    public init(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "sempre", "always", "": self = .always
        case "noite", "night": self = .night
        default:
            let parts = t.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
                self = .daily(hour: parts[0], minute: parts[1])
            } else {
                self = .invalid
            }
        }
    }

    public static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        return h >= 22 || h < 7
    }

    /// Está na hora? `lastRun` evita rodar duas vezes no mesmo dia.
    public func isDue(now: Date, lastRun: Date?, userAway: Bool, calendar: Calendar = .current) -> Bool {
        switch self {
        case .always: return true
        case .night: return Self.isNight(now, calendar: calendar) || userAway
        case let .daily(h, m):
            guard let start = calendar.date(bySettingHour: h, minute: m, second: 0, of: now), now >= start else { return false }
            if let lastRun, lastRun >= start { return false }
            return true
        case .invalid: return false
        }
    }
}

/// Orçamento de uma tarefa. Acabou → volta para casa e pergunta.
public struct Budget: Sendable, Equatable, Codable {
    public var maxActions: Int
    public var maxTokens: Int
    public var maxSeconds: TimeInterval
    public var maxUSD: Double

    public init(maxActions: Int = 40, maxTokens: Int = 300_000, maxSeconds: TimeInterval = 3600, maxUSD: Double = 1.5) {
        self.maxActions = maxActions
        self.maxTokens = maxTokens
        self.maxSeconds = maxSeconds
        self.maxUSD = maxUSD
    }

    public init(goal: Goal.DailyBudget?) {
        self.init(maxActions: goal?.acoes ?? 40, maxTokens: goal?.tokens ?? 300_000, maxUSD: goal?.usd ?? 1.5)
    }
}

/// Conta o gasto de uma tarefa contra o orçamento.
public struct BudgetLedger: Sendable, Equatable, Codable {
    public var budget: Budget
    public var actions = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var usd = 0.0
    public var started: Date

    public init(budget: Budget, started: Date = Date()) {
        self.budget = budget
        self.started = started
    }

    public var tokens: Int { inputTokens + outputTokens }

    public mutating func charge(actions a: Int = 0, input: Int = 0, output: Int = 0, price: ModelPrice?) {
        actions += a
        inputTokens += input
        outputTokens += output
        if let price { usd += price.cost(input: input, output: output) }
    }

    /// O que acabou, se algo acabou. `checkTime: false` para o orçamento do dia
    /// (onde só contam ações, tokens e dinheiro).
    public func exhausted(now: Date = Date(), checkTime: Bool = true) -> String? {
        if actions >= budget.maxActions { return "ações" }
        if tokens >= budget.maxTokens { return "tokens" }
        if usd >= budget.maxUSD { return "dinheiro" }
        if checkTime, now.timeIntervalSince(started) >= budget.maxSeconds { return "tempo" }
        return nil
    }

    /// Ações restantes (o corpo mostra como pontos carregados).
    public var actionsLeft: Int { max(0, budget.maxActions - actions) }
}

/// Preço por milhão de tokens, para estimar custo.
public struct ModelPrice: Sendable, Equatable, Codable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
    }

    public func cost(input: Int, output: Int) -> Double {
        Double(input) / 1e6 * inputPerMTok + Double(output) / 1e6 * outputPerMTok
    }

    /// Tabela conhecida (ids exatos). Desconhecido → `nil` (custo não estimado).
    public static func known(_ brainID: String) -> ModelPrice? {
        let model = brainID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? brainID
        switch model {
        case "claude-opus-5-5": return ModelPrice(inputPerMTok: 4, outputPerMTok: 20)
        case "claude-sonnet-5-5": return ModelPrice(inputPerMTok: 2, outputPerMTok: 10)
        case "claude-haiku-4-5": return ModelPrice(inputPerMTok: 1, outputPerMTok: 5)
        case "claude-fable-5-1": return ModelPrice(inputPerMTok: 10, outputPerMTok: 50)
        default: return brainID.hasPrefix("ollama:") || brainID == "offline" ? ModelPrice(inputPerMTok: 0, outputPerMTok: 0) : nil
        }
    }
}

/// Uma tarefa no quadro da casa.
public struct BoardTask: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable { case todo, doing, done, blocked, needsYou = "precisa_de_voce" }

    /// Uma tentativa, com a hipótese registrada (para não repetir a mesma).
    public struct Attempt: Sendable, Equatable, Codable {
        public var hypothesis: String
        public var result: String
        public var success: Bool
        public var at: Date

        public init(hypothesis: String, result: String, success: Bool, at: Date = Date()) {
            self.hypothesis = hypothesis
            self.result = result
            self.success = success
            self.at = at
        }
    }

    public var id: String
    public var goalID: String
    public var title: String
    public var status: Status
    public var attempts: [Attempt]
    public var branch: String?
    public var note: String?
    public var created: Date
    public var updated: Date
    public var ledger: BudgetLedger?

    public init(id: String, goalID: String, title: String, status: Status = .todo, attempts: [Attempt] = [],
                branch: String? = nil, note: String? = nil, created: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.title = title
        self.status = status
        self.attempts = attempts
        self.branch = branch
        self.note = note
        self.created = created
        self.updated = created
    }

    public static let maxApproaches = 3
    public var isOpen: Bool { status == .todo || status == .doing }
}
