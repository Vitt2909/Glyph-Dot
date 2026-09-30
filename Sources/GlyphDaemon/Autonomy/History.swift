import Foundation
import GlyphCore

/// Uma entrada do histórico: tudo que o Glyph faz sozinho vai para cá, com a
/// inversa quando existe.
public struct HistoryEntry: Sendable, Codable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Codable { case autonomous, user }
    public enum Outcome: String, Sendable, Codable { case done, failed, denied, observed, discarded, noted, undone }

    /// Como desfazer, quando dá.
    public struct Inverse: Sendable, Codable, Equatable {
        public var tool: String
        public var input: JSONValue
        public var summary: String

        public init(tool: String, input: JSONValue, summary: String) {
            self.tool = tool
            self.input = input
            self.summary = summary
        }
    }

    public var id: String
    public var ts: Date
    public var origin: Origin
    public var summary: String
    public var actionClass: ActionClass?
    public var scope: String?
    public var tool: String?
    public var outcome: Outcome
    public var detail: String?
    public var inverse: Inverse?
    public var score: Double?
    /// O que disparou (evento, pedido, horário). "Por que você fez isso?"
    public var trigger: String?
    /// O que permitiu, registrado na hora.
    public var authorization: Authorization?
    public var cost: ActionCost?
    /// Arquivo:linha, trecho curto, ramo.
    public var evidence: String?

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), ts: Date = Date(), origin: Origin,
                summary: String, actionClass: ActionClass? = nil, scope: String? = nil, tool: String? = nil,
                outcome: Outcome, detail: String? = nil, inverse: Inverse? = nil, score: Double? = nil,
                trigger: String? = nil, authorization: Authorization? = nil, cost: ActionCost? = nil,
                evidence: String? = nil) {
        self.id = id
        self.ts = ts
        self.origin = origin
        self.summary = summary
        self.actionClass = actionClass
        self.scope = scope
        self.tool = tool
        self.outcome = outcome
        self.detail = detail
        self.inverse = inverse
        self.score = score
        self.trigger = trigger
        self.authorization = authorization
        self.cost = cost
        self.evidence = evidence
    }

    /// O que a explicação precisa.
    public var why: WhyRecord {
        WhyRecord(id: id, origin: origin.rawValue, summary: summary, outcome: outcome.rawValue, detail: detail,
                  actionClass: actionClass, scope: scope, tool: tool, trigger: trigger, authorization: authorization,
                  cost: cost, evidence: evidence, undoable: inverse != nil)
    }
}

/// Histórico em JSON por linha (`casa/historico.jsonl`): só acrescenta.
public actor HistoryStore {
    private let url: URL?
    public private(set) var entries: [HistoryEntry] = []

    public init(url: URL?) {
        self.url = url
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            entries = text.split(separator: "\n").compactMap {
                try? JSONDecoder.glyph.decode(HistoryEntry.self, from: Data($0.utf8))
            }
        }
    }

    @discardableResult
    public func append(_ e: HistoryEntry) -> HistoryEntry {
        entries.append(e)
        if let url {
            let e2 = JSONEncoder.glyph
            e2.outputFormatting = [.sortedKeys]
            if let data = try? e2.encode(e) {
                var line = data
                line.append(0x0A)
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(line)
                    try? h.close()
                } else {
                    try? line.write(to: url)
                }
            }
        }
        return e
    }

    public func entry(_ id: String) -> HistoryEntry? { entries.last { $0.id == id } }

    public func recent(_ n: Int = 20) -> [HistoryEntry] { Array(entries.suffix(n)) }

    /// Entradas de um dia (para o diário do M4).
    public func entries(on day: Date, calendar: Calendar = .current) -> [HistoryEntry] {
        entries.filter { calendar.isDate($0.ts, inSameDayAs: day) }
    }

    public func entries(since: Date) -> [HistoryEntry] {
        entries.filter { $0.ts >= since }
    }
}
