import Foundation
import GlyphCore

/// Uma ação planejada para uma intenção.
public struct PlannedAction: Sendable, Equatable {
    public var tool: String
    public var input: JSONValue
    public var summary: String
    /// Como interpretar o resultado.
    public var kind: Kind

    public enum Kind: String, Sendable, Equatable { case testRun, check, generic }

    public init(tool: String, input: JSONValue, summary: String, kind: Kind = .generic) {
        self.tool = tool
        self.input = input
        self.summary = summary
        self.kind = kind
    }
}

public struct Proposal: Sendable, Equatable {
    public var intent: Intent
    public var action: PlannedAction?
    /// O evento que disparou, em uma linha (vai para o histórico).
    public var trigger: String?

    public init(intent: Intent, action: PlannedAction?, trigger: String? = nil) {
        self.intent = intent
        self.action = action
        self.trigger = trigger
    }
}

/// Reflexos: regras baratas e determinísticas que transformam eventos em
/// intenções, sem gastar modelo. O cérebro entra para planos longos (M4).
public enum Reflexes {
    public struct Context: Sendable {
        /// Repositórios que o usuário marcou (sensores de git/arquivos).
        public var watched: [String]
        public init(watched: [String]) { self.watched = watched.map { Scope.normalize(ShellTool.expand($0)) } }
    }

    public static func propose(_ e: SensorEvent, context: Context) -> [Proposal] {
        switch e.kind {
        case "shell.exit":
            guard let cmd = e.cmd?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty, let code = e.code,
                  code != 0, code != 130, let cwd = e.cwd else { return [] }
            // Só comandos de teste, e só se forem reexecutáveis sem efeito (compute).
            guard FailureParser.looksLikeTestCommand(cmd), CommandClassifier.classify(cmd).actionClass == .compute else { return [] }
            let root = GitWatcher.root(of: cwd).map { Scope.normalize($0) } ?? Scope.normalize(ShellTool.expand(cwd))
            let watched = context.watched.contains { Scope.contains($0, root) }
            let name = (root as NSString).lastPathComponent
            let intent = Intent(source: "terminal", summary: "testes falharam em \(name)/",
                                relevance: watched ? 0.85 : 0.75, confidence: 0.9, urgency: 0.9,
                                interruptCost: 0.2, actionClass: .compute, scope: root)
            let action = PlannedAction(tool: "shell", input: .object(["command": .string(cmd), "cwd": .string(ShellTool.expand(cwd))]),
                                       summary: "rodar \(cmd) em \(name)", kind: .testRun)
            let trigger = "`\(cmd)` saiu com código \(code) em \(Explanation.shortPath(ShellTool.expand(cwd)))"
            return [Proposal(intent: intent, action: action, trigger: trigger)]
        default:
            return []
        }
    }
}

/// O canal com o corpo, do ponto de vista da autonomia.
public protocol BodyChannel: Sendable {
    func cue(_ message: Message) async
    /// `key` deixa o "sempre permitir" criar a regra no escopo certo.
    func approve(_ request: ApprovalRequest, key: TrustKey?) async -> Bool
    func world() async -> WorldUpdate?
    func isPaused() async -> Bool
}

/// O loop de autonomia: perceber → avaliar → decidir → agir → registrar.
public actor AutonomyEngine {
    public let tools: ToolRegistry
    public let policy: PolicyStore
    public let history: HistoryStore
    public let context: Reflexes.Context
    private let body: any BodyChannel
    private let log: DaemonLog
    private var recent: [String: Date] = [:]
    /// Não repete a mesma intenção antes disto.
    public var cooldown: TimeInterval = 60

    public init(tools: ToolRegistry, policy: PolicyStore, history: HistoryStore, context: Reflexes.Context,
                body: any BodyChannel, log: DaemonLog) {
        self.tools = tools
        self.policy = policy
        self.history = history
        self.context = context
        self.body = body
        self.log = log
    }

    /// Um evento chegou. Devolve o que foi feito (para testes e para o log).
    @discardableResult
    public func handle(_ event: SensorEvent) async -> [HistoryEntry] {
        guard !(await body.isPaused()) else { return [] }
        var out: [HistoryEntry] = []
        for p in Reflexes.propose(event, context: context) {
            out.append(await consider(p))
        }
        return out
    }

    func consider(_ p: Proposal) async -> HistoryEntry {
        let key = "\(p.intent.summary)|\(p.intent.scope)"
        if let last = recent[key], Date().timeIntervalSince(last) < cooldown {
            return HistoryEntry(origin: .autonomous, summary: p.intent.summary, outcome: .discarded, detail: "repetida",
                                trigger: p.trigger)
        }
        recent[key] = Date()

        let w = await body.world()
        let typing = (w?.idleSeconds ?? 60) < 3
        let focus = FocusEstimator.focus(w?.focus ?? .normal, typingRecently: typing)
        let score = IntentScorer.score(p.intent, focus: focus, calibrator: await policy.calibrator)
        let verdict = IntentScorer.verdict(score)
        log.log("intenção: \(p.intent.summary) S=\(String(format: "%.2f", score)) → \(verdict.rawValue)")
        let base = HistoryEntry(origin: .autonomous, summary: p.intent.summary, actionClass: p.intent.actionClass,
                                scope: p.intent.scope, tool: p.action?.tool, outcome: .discarded, score: score,
                                trigger: p.trigger)
        let scoreText = "pontuação \(String(format: "%.2f", score))"

        switch verdict {
        case .discard:
            var e = base; e.detail = "\(scoreText), abaixo de 0,3"
            return await history.append(e)
        case .note:
            await point(at: p.action, world: w)
            var e = base; e.outcome = .noted; e.detail = "\(scoreText): só aponta abaixo de 0,6"
            return await history.append(e)
        case .act:
            break
        }
        guard let action = p.action, let tool = tools[action.tool] else {
            var e = base; e.outcome = .noted
            return await history.append(e)
        }

        let cls = tool.classify(action.input)
        let tkey = TrustKey(cls, p.intent.scope)
        let decision = await policy.decide(tkey, tool: action.tool, trusted: p.intent.trusted, userInitiated: false)
        switch decision {
        case let .deny(why):
            var e = base; e.outcome = .denied; e.detail = why
            e.authorization = Authorization(.policy, actionClass: cls, scope: p.intent.scope, note: why)
            return await history.append(e)
        case let .observe(why):
            await point(at: action, world: w)
            var e = base; e.outcome = .observed; e.detail = why
            e.authorization = await policy.authorization(tkey, tool: action.tool)
            return await history.append(e)
        case .ask, .askTwice:
            let req = ApprovalRequest(action: action.tool, target: action.summary, actionClass: cls,
                                      why: "\(p.intent.summary) — \(action.summary)?", timeoutSec: 120)
            var ok = await body.approve(req, key: tkey)
            if ok, case .askTwice = decision {
                ok = await body.approve(ApprovalRequest(action: action.tool, target: action.summary, actionClass: cls,
                                                        why: "tem certeza? isto não tem volta.", timeoutSec: 120), key: nil)
            }
            await policy.record(tkey, approved: ok)
            guard ok else {
                var e = base; e.outcome = .denied; e.detail = "não aprovado"
                e.authorization = Authorization(.refused, actionClass: cls, scope: p.intent.scope)
                return await history.append(e)
            }
            var e = base
            e.authorization = Authorization(.card, actionClass: cls, scope: p.intent.scope, at: Date())
            return await run(action, tool: tool, intent: p.intent, entry: e, announce: true, world: w)
        case .actAndTell, .actSilently:
            var e = base
            e.authorization = await policy.authorization(tkey, tool: action.tool)
            return await run(action, tool: tool, intent: p.intent, entry: e, announce: decision == .actAndTell, world: w)
        }
    }

    /// Só aponta: vai até a janela e olha. Silêncio por padrão.
    func point(at action: PlannedAction?, world w: WorldUpdate?) async {
        let place = action.flatMap { tools[$0.tool]?.place } ?? .none
        if let win = GlyphServer.window(for: place, in: w) {
            await body.cue(.bodyGoto(BodyGoto(target: .window(pid: win.pid, frame: win.frame))))
        }
        await body.cue(.bodyEmote(BodyEmote(clip: "look", dot: .glance)))
    }

    func run(_ action: PlannedAction, tool: any Tool, intent: Intent, entry: HistoryEntry, announce: Bool,
             world w: WorldUpdate?) async -> HistoryEntry {
        if let win = GlyphServer.window(for: tool.place, in: w) {
            await body.cue(.bodyGoto(BodyGoto(target: .window(pid: win.pid, frame: win.frame))))
        }
        await body.cue(.bodyEmote(BodyEmote(clip: "work", dot: .trail)))
        var e = entry
        let output: ToolOutput
        let started = Date()
        do {
            output = try await tool.run(action.input)
            e.cost = ActionCost(seconds: Date().timeIntervalSince(started))
        } catch {
            e.cost = ActionCost(seconds: Date().timeIntervalSince(started))
            e.outcome = .failed
            e.detail = "\(error)"
            await policy.recordOutcome(intent.actionClass, predicted: intent.confidence, success: false)
            await body.cue(.bodyEmote(BodyEmote(clip: "error", dot: .shrink)))
            if announce { await body.cue(.bubbleSay(BubbleSay(text: "hm. não consegui rodar."))) }
            return await history.append(e)
        }
        await policy.recordOutcome(intent.actionClass, predicted: intent.confidence, success: true)
        e.outcome = .done

        switch action.kind {
        case .testRun:
            if output.isError, let f = FailureParser.first(in: output.text) {
                e.detail = "\(f.count) falha(s); primeira em \(f.file)\(f.line.map { ":\($0)" } ?? "")"
                e.evidence = f.short
                // Aponta o arquivo: segura o alfinete.
                await body.cue(.bodyEmote(BodyEmote(clip: "point", dot: .alert, sticker: "alfinete")))
                if announce {
                    let n = f.count > 1 ? "\(f.count) falhas" : "falha"
                    await body.cue(.bubbleSay(BubbleSay(text: "\(n): \(f.short)", durationSec: 8)))
                }
            } else if output.isError {
                e.detail = "falhou sem arquivo identificável"
                await body.cue(.bodyEmote(BodyEmote(clip: "error", dot: .shrink)))
                if announce { await body.cue(.bubbleSay(BubbleSay(text: "ainda falha. veja o terminal."))) }
            } else {
                e.detail = "passou ao rodar de novo"
                await body.cue(.sceneCue(SceneCue(event: .testsPassed)))
                await body.cue(.bodyEmote(BodyEmote(clip: "idle", dot: .steady)))
                if announce { await body.cue(.bubbleSay(BubbleSay(text: "passou agora. instável?"))) }
            }
        case .check, .generic:
            e.detail = String(output.text.suffix(200))
            if announce { await body.cue(.bubbleSay(BubbleSay(text: output.isError ? "deu erro." : "feito."))) }
        }
        log.log("autonomia: \(action.summary) → \(e.detail ?? "")")
        return await history.append(e)
    }
}
