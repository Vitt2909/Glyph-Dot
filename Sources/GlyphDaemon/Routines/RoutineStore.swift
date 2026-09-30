import Foundation
import GlyphCore

/// Uma sessão de ensino em andamento (`casa/ensino.json`).
public struct TeachingSession: Sendable, Codable, Equatable {
    public var name: String
    public var parameters: [String: String]
    public var started: Date
    public var steps: [DemoStep]
}

/// Sessões de ensino, rascunhos (`skills/_rascunhos/rotina-*.json`) e rotinas
/// aprovadas (`skills/rotina-*.json`), com um `.md` legível ao lado.
public struct RoutineStore: Sendable {
    public let paths: GlyphPaths

    public init(paths: GlyphPaths) { self.paths = paths }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case busy(String)
        case none
        case notFound(String)
        case invalid(String)
        case needsRehearsal
        case notApproved(String)

        public var description: String {
            switch self {
            case let .busy(n): return "já estou aprendendo \(n). /pronto ou /cancelar primeiro."
            case .none: return "não estou aprendendo nada."
            case let .notFound(n): return "não conheço a rotina \(n)."
            case let .invalid(m): return m
            case .needsRehearsal: return "primeiro um ensaio com esses parâmetros."
            case let .notApproved(n): return "\(n) ainda é rascunho: glyphd rotina aprovar \(n)"
            }
        }
    }

    var sessionURL: URL { paths.casa.appendingPathComponent("ensino.json") }
    func draftURL(_ n: String, _ ext: String) -> URL { paths.skillDrafts.appendingPathComponent("rotina-\(n).\(ext)") }
    func activeURL(_ n: String, _ ext: String) -> URL { paths.skills.appendingPathComponent("rotina-\(n).\(ext)") }

    // MARK: - Ensinar

    public func current() -> TeachingSession? {
        (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder.glyph.decode(TeachingSession.self, from: $0) }
    }

    @discardableResult
    public func start(name: String, parameters: [String: String], now: Date = Date()) throws -> TeachingSession {
        if let c = current() { throw StoreError.busy(c.name) }
        guard Routine.validName(name) else { throw StoreError.invalid("nome: letras, números, - e _") }
        guard parameters.keys.allSatisfy(Routine.validName), parameters.values.allSatisfy(Routine.isSafeValue) else {
            throw StoreError.invalid("parâmetros como cliente=acme (valor sem símbolos de shell)")
        }
        let s = TeachingSession(name: name, parameters: parameters, started: now, steps: [])
        try write(s)
        return s
    }

    /// Anota um comando que terminou (só comando, pasta e código).
    @discardableResult
    public func record(_ e: SensorEvent) -> TeachingSession? {
        guard e.kind == "shell.exit", var s = current(), let cmd = e.cmd, let cwd = e.cwd, let code = e.code else { return nil }
        s.steps.append(DemoStep(command: cmd, cwd: cwd, code: code))
        if s.steps.count > 200 { s.steps.removeFirst() }
        try? write(s)
        return s
    }

    public func cancel() throws {
        guard current() != nil else { throw StoreError.none }
        try FileManager.default.removeItem(at: sessionURL)
    }

    /// Fecha a sessão e escreve o rascunho.
    public func finish(now: Date = Date()) throws -> Routine {
        guard let s = current() else { throw StoreError.none }
        let r = Routine.draft(name: s.name, demo: s.steps, parameters: s.parameters, created: now)
        try save(r)
        try? FileManager.default.removeItem(at: sessionURL)
        return r
    }

    func write(_ s: TeachingSession) throws {
        try FileManager.default.createDirectory(at: paths.casa, withIntermediateDirectories: true)
        try JSONEncoder.glyph.encode(s).write(to: sessionURL, options: .atomic)
    }

    // MARK: - Rotinas

    public func save(_ r: Routine) throws {
        let dir = r.approved ? paths.skills : paths.skillDrafts
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = r.approved ? activeURL(r.name, "json") : draftURL(r.name, "json")
        let md = r.approved ? activeURL(r.name, "md") : draftURL(r.name, "md")
        try JSONEncoder.glyph.encode(r).write(to: json, options: .atomic)
        try r.render().write(to: md, atomically: true, encoding: .utf8)
    }

    public func load(_ name: String) -> Routine? {
        guard Routine.validName(name) else { return nil }
        for url in [activeURL(name, "json"), draftURL(name, "json")] {
            if let data = try? Data(contentsOf: url), let r = try? JSONDecoder.glyph.decode(Routine.self, from: data) { return r }
        }
        return nil
    }

    public func mdPath(_ r: Routine) -> String { (r.approved ? activeURL(r.name, "md") : draftURL(r.name, "md")).path }

    public func list() -> [Routine] {
        var out: [Routine] = []
        for dir in [paths.skills, paths.skillDrafts] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasPrefix("rotina-") && f.hasSuffix(".json") {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                   let r = try? JSONDecoder.glyph.decode(Routine.self, from: data) { out.append(r) }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Sua aprovação: o rascunho vira rotina ativa.
    public func approve(_ name: String) throws -> Routine {
        guard var r = load(name) else { throw StoreError.notFound(name) }
        guard !r.approved else { return r }
        r.approved = true
        try save(r)
        try? FileManager.default.removeItem(at: draftURL(name, "json"))
        try? FileManager.default.removeItem(at: draftURL(name, "md"))
        return r
    }

    /// Ensaio: mostra os passos concretos, não roda nada, e libera executar
    /// com estes parâmetros.
    public func rehearse(_ name: String, values: [String: String]) throws -> [RoutineStep] {
        guard var r = load(name) else { throw StoreError.notFound(name) }
        guard let steps = r.instantiate(values) else {
            throw StoreError.invalid("parâmetros: " + r.parameters.keys.sorted().map { "\($0)=…" }.joined(separator: " ")
                                     + " (sem símbolos de shell)")
        }
        if !r.wasRehearsed(values) {
            r.rehearsed.append(values)
            if r.rehearsed.count > 50 { r.rehearsed.removeFirst() }
            try save(r)
        }
        return steps
    }

    public struct RunResult: Sendable, Equatable {
        public var ran: Int
        public var skipped: [String]
        public var stoppedAt: String?
        public var text: String
    }

    /// Roda uma rotina aprovada e já ensaiada com estes valores. Cada passo
    /// pergunta à política (`decide`); o que ela manda pedir, pede (`approve`).
    public func run(_ name: String, values: [String: String],
                    decide: @Sendable (RoutineStep) async -> PolicyDecision,
                    approve: @Sendable (RoutineStep, _ twice: Bool) async -> Bool,
                    exec: @Sendable (RoutineStep) async throws -> ToolOutput) async throws -> RunResult {
        guard let r = load(name) else { throw StoreError.notFound(name) }
        guard r.approved else { throw StoreError.notApproved(name) }
        guard let steps = r.instantiate(values) else { throw StoreError.invalid("parâmetros inválidos") }
        guard r.wasRehearsed(values) else { throw StoreError.needsRehearsal }
        var ran = 0
        var skipped: [String] = []
        for s in steps {
            if s.forbidden { skipped.append("\(s.command): proibido"); continue }
            switch await decide(s) {
            case .actSilently, .actAndTell: break
            case .ask:
                guard await approve(s, false) else {
                    return RunResult(ran: ran, skipped: skipped, stoppedAt: s.command, text: "parei: \(s.command) não foi aprovado.")
                }
            case .askTwice:
                guard await approve(s, true) else {
                    return RunResult(ran: ran, skipped: skipped, stoppedAt: s.command, text: "parei: \(s.command) não foi aprovado.")
                }
            case let .observe(why), let .deny(why):
                return RunResult(ran: ran, skipped: skipped, stoppedAt: s.command, text: "parei em \(s.command): \(why)")
            }
            let out = try await exec(s)
            ran += 1
            if out.isError {
                return RunResult(ran: ran, skipped: skipped, stoppedAt: s.command, text: "parei: \(s.command) falhou.")
            }
        }
        return RunResult(ran: ran, skipped: skipped, stoppedAt: nil, text: "\(r.name): \(ran) passos feitos.")
    }

    /// `cliente=acme projeto=x` → dicionário.
    public static func parseValues(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for a in args {
            let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty { out[parts[0]] = parts[1] }
        }
        return out
    }
}
