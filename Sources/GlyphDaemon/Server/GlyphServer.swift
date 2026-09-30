import Foundation
import GlyphCore
import GlyphIPC

/// O `glyphd` em execução: aceita corpos no socket, conversa com eles pelo
/// Glyph Protocol, roda o cérebro quando o usuário chama e a autonomia quando
/// os sensores percebem algo.
///
/// Nunca executa nada a pedido do corpo: o corpo só percebe, chama, aprova e
/// freia. Toda ação passa pela `Policy`.
public actor GlyphServer {
    public struct Options: Sendable {
        public var socketPath: String
        public var sensorSocketPath: String?
        public var verifier: PeerVerifier
        /// Deixe corpos não verificados aprovarem. Só para desenvolvimento.
        public var trustUnverifiedBodies: Bool
        public var approvalTimeout: Double
        /// Agentes externos que falam o Glyph Protocol (papel `brain`) podem
        /// animar o corpo. Desligado por padrão (M6).
        public var allowExternalAgents: Bool

        public init(socketPath: String, sensorSocketPath: String? = nil, verifier: PeerVerifier = PeerVerifier(),
                    trustUnverifiedBodies: Bool = false, approvalTimeout: Double = 120, allowExternalAgents: Bool = false) {
            self.socketPath = socketPath
            self.sensorSocketPath = sensorSocketPath
            self.verifier = verifier
            self.trustUnverifiedBodies = trustUnverifiedBodies
            self.approvalTimeout = approvalTimeout
            self.allowExternalAgents = allowExternalAgents
        }
    }

    final class Session: @unchecked Sendable {
        let id: Int
        let connection: LineConnection
        let trust: PeerTrust
        var world: WorldUpdate?
        /// `.brain` quando é um agente externo (depois do `hello`).
        var role: Peer = .body
        var agentName: String?
        var recent: [Date] = []

        init(id: Int, connection: LineConnection, trust: PeerTrust) {
            self.id = id
            self.connection = connection
            self.trust = trust
        }
    }

    struct Pending {
        var continuation: CheckedContinuation<Bool, Never>
        var key: TrustKey?
        var tool: String
    }

    public let options: Options
    private var agent: AgentLoop
    public let policy: PolicyStore
    public let history: HistoryStore
    private let log: DaemonLog
    private var server: UnixSocketServer?
    private var sensorServer: SensorServer?
    private var autonomy: AutonomyEngine?
    private var goals: GoalRunner?
    private var extraTasks: [Task<Void, Never>] = []
    private var sessions: [Int: Session] = [:]
    private var nextSession = 0
    private var nextMessage = 0
    private var pendingApprovals: [String: Pending] = [:]
    private var busy = false
    private var currentTask: Task<Void, Never>?
    private var chatHistory: [ChatTurn] = []
    public private(set) var paused = false
    /// Entregas (ideia 1): o que você soltou sobre o Glyph, por oferta.
    private var delivery: DeliveryRunner?
    private var grants: [String: DeliveryGrant] = [:]
    private var nextOffer = 0
    /// Tipos cujo conteúdo você já deixou ir para o cérebro na nuvem (nesta sessão).
    private var deliveryConsent: Set<DeliveredItem.Kind> = []
    /// Marcadores dos projetos (ideia 5).
    private var projects: ProjectTracker?
    /// Ensinar mostrando (ideia 2).
    private var routines: RoutineStore?

    public init(options: Options, agent: AgentLoop, log: DaemonLog,
                policy: PolicyStore = PolicyStore(policyURL: nil, trustURL: nil),
                history: HistoryStore = HistoryStore(url: nil)) {
        self.options = options
        self.agent = agent
        self.log = log
        self.policy = policy
        self.history = history
    }

    public func start() throws {
        let s = UnixSocketServer(path: options.socketPath)
        s.onConnection = { [weak self] conn in
            guard let self else { return }
            Task { await self.accept(conn) }
        }
        try s.start()
        server = s
        if let path = options.sensorSocketPath {
            let sensors = SensorServer(path: path)
            sensors.onEvent = { [weak self] e in
                guard let self else { return }
                Task { await self.sensorEvent(e) }
            }
            try sensors.start()
            sensorServer = sensors
        }
        log.log("glyphd ouvindo em \(options.socketPath) (cérebro: \(agent.brain.id))")
    }

    /// Liga a autonomia (M3). Separado do `init` porque o motor precisa do
    /// servidor como canal com o corpo.
    public func attach(autonomy: AutonomyEngine) {
        self.autonomy = autonomy
    }

    /// Liga os objetivos (M4).
    public func attach(goals: GoalRunner) {
        self.goals = goals
    }

    /// Liga o ensinar mostrando.
    public func attach(routines: RoutineStore) {
        self.routines = routines
    }

    /// Liga a retomada de projetos.
    public func attach(projects: ProjectTracker) {
        self.projects = projects
    }

    /// Liga as entregas (arquivos soltos sobre o Glyph).
    public func attach(delivery: DeliveryRunner) {
        self.delivery = delivery
    }

    public func attach(task: Task<Void, Never>) {
        extraTasks.append(task)
    }

    public func stop() {
        server?.stop()
        sensorServer?.stop()
        extraTasks.forEach { $0.cancel() }
        currentTask?.cancel()
        for s in sessions.values { s.connection.close() }
        sessions.removeAll()
    }

    public var sessionCount: Int { sessions.count }

    // MARK: - Conexões

    private func accept(_ conn: LineConnection) {
        let trust = options.verifier.trust(conn.peer)
        if case let .rejected(why) = trust {
            log.log("conexão recusada: \(why)")
            conn.close()
            return
        }
        nextSession += 1
        let session = Session(id: nextSession, connection: conn, trust: trust)
        sessions[session.id] = session
        let id = session.id
        conn.onLine = { [weak self] result in
            guard let self else { return }
            Task { await self.receive(result, from: id) }
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            Task { await self.closed(id) }
        }
        conn.start()
        log.log("corpo \(id) conectado (\(trust == .verifiedBody ? "assinatura conferida" : "não verificado"))")
    }

    private func closed(_ id: Int) {
        sessions[id] = nil
        log.log("corpo \(id) saiu")
    }

    private func receive(_ result: Result<Envelope, Error>, from id: Int) async {
        guard let session = sessions[id] else { return }
        let env: Envelope
        switch result {
        case let .success(e): env = e
        case let .failure(e):
            log.log("corpo \(id): linha inválida (\(e))")
            return
        }
        if case let .hello(h) = env.message, h.role == .brain, session.role == .body {
            guard options.allowExternalAgents else {
                log.log("agente externo \(h.name ?? "?") recusado (agentes_externos.corpo: false)")
                session.connection.close()
                return
            }
            session.role = .brain
            session.agentName = String((h.name ?? "agente").prefix(40))
            log.log("agente externo \(session.agentName!) conectado (sessão \(id)): só anima o corpo")
        }
        do {
            try ProtocolValidator.validate(env, from: session.role)
        } catch {
            log.log("sessão \(id): \(error)")
            return
        }
        if session.role == .brain {
            externalAgentMessage(env.message, session: session)
            return
        }
        switch env.message {
        case .hello:
            send(.hello(Hello(role: .brain, capabilities: ["agent", "tools", "autonomy", "brake"], name: "glyphd")), to: session)
        case let .worldUpdate(w):
            session.world = w
        case let .inputSummon(s):
            await summon(s, session: session)
        case let .inputBrake(b):
            await brake(b.engage)
        case let .inputDrop(d):
            offerDelivery(d, session: session)
        case let .offerChoice(c):
            await chooseDelivery(c, session: session)
        case let .taskShelf(t):
            if let goals, await goals.shelf(t.taskId, park: t.park) != nil {
                log.log("tarefa \(t.taskId) \(t.park ? "na prateleira" : "retomada")")
            } else {
                send(.bubbleSay(BubbleSay(text: "não achei essa tarefa.")), to: session)
            }
        case let .approvalResponse(r):
            guard session.trust.canApprove || options.trustUnverifiedBodies else {
                log.log("corpo \(id) tentou aprovar sem assinatura conferida: ignorado")
                return
            }
            await resolveApproval(r)
        default:
            break
        }
    }

    // MARK: - Ensinar mostrando

    /// Comandos de ensino no campo de chamada. Devolve `true` se tratou.
    private func routineCommand(_ text: String, session: Session) async -> Bool {
        guard let routines else { return false }
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return false }
        let natural = text.lowercased().hasPrefix("aprenda esta rotina") || text.lowercased().hasPrefix("aprenda essa rotina")
        func say(_ t: String) { send(.bubbleSay(BubbleSay(text: t, durationSec: 8)), to: session) }
        do {
            switch natural ? "/ensinar" : first {
            case "/ensinar":
                let rest = natural ? Array(words.dropFirst(3)) : Array(words.dropFirst())
                let name = rest.first { !$0.contains("=") } ?? "rotina-\(routines.list().count + 1)"
                let s = try routines.start(name: name, parameters: RoutineStore.parseValues(rest))
                send(.taskUpdate(TaskUpdate(taskId: "ensino-\(s.name)", step: "anotando", progress: 0, object: "diario",
                                            title: "aprendendo \(s.name)", state: .doing)), to: session)
                send(.bodyEmote(BodyEmote(clip: "look", dot: .trail, sticker: "diario")), to: session)
                say("anotando. /pronto quando acabar.")
            case "/pronto":
                let r = try routines.finish()
                send(.taskUpdate(TaskUpdate(taskId: "ensino-\(r.name)", step: "rascunho", progress: 1, object: "diario",
                                            title: r.name, state: .needsYou, pending: "\(r.steps.count) passos; /aprovar \(r.name)",
                                            open: routines.mdPath(r))), to: session)
                say("\(r.steps.count) passos. veja e /aprovar \(r.name)")
            case "/cancelar":
                let s = routines.current()
                try routines.cancel()
                if let s {
                    send(.taskUpdate(TaskUpdate(taskId: "ensino-\(s.name)", step: "cancelado", progress: 0, object: "diario",
                                                state: .parked)), to: session)
                }
                say("esqueci a demonstração.")
            case "/aprovar":
                guard words.count >= 2 else { say("/aprovar <nome>"); return true }
                let r = try routines.approve(words[1])
                await history.append(HistoryEntry(origin: .user, summary: "aprovou a rotina \(r.name)", outcome: .done,
                                                  authorization: Authorization(.request)))
                send(.taskUpdate(TaskUpdate(taskId: "ensino-\(r.name)", step: "aprovada", progress: 1, object: "diario",
                                            title: r.name, state: .done, result: "rotina ativa.")), to: session)
                say("\(r.name): rotina ativa.")
            case "/rotina":
                guard words.count >= 2 else { say("/rotina <nome> param=valor"); return true }
                await runRoutine(words[1], values: RoutineStore.parseValues(Array(words.dropFirst(2))), routines: routines, session: session)
            default:
                return false
            }
        } catch {
            say("\(error)")
        }
        return true
    }

    /// Pelo campo de chamada: ensaia na primeira vez; depois roda, com cada
    /// passo passando pela política e os irreversíveis pedindo cartão.
    private func runRoutine(_ name: String, values: [String: String], routines: RoutineStore, session: Session) async {
        func say(_ t: String) { send(.bubbleSay(BubbleSay(text: t, durationSec: 8)), to: session) }
        guard let r = routines.load(name) else { say("não conheço \(name)."); return }
        guard r.approved else { say("\(name) ainda é rascunho."); return }
        do {
            if !r.wasRehearsed(values) {
                let steps = try routines.rehearse(name, values: values)
                send(.taskUpdate(TaskUpdate(taskId: "rotina-\(name)", step: "ensaio", progress: 0.5, object: "diario",
                                            title: name, state: .needsYou, pending: "ensaio: \(steps.count) passos. repita para rodar.",
                                            open: routines.mdPath(r))), to: session)
                say("ensaio: \(steps.count) passos. repita para rodar.")
                return
            }
            guard let shell = agent.tools["shell"] else { say("sem shell."); return }
            busy = true
            defer { busy = false }
            send(.bodyEmote(BodyEmote(clip: "work", dot: .trail)), to: session)
            let policy = self.policy
            let result = try await routines.run(name, values: values, decide: { s in
                await policy.decide(TrustKey(s.actionClass, Scope.normalize(ShellTool.expand(s.cwd))), tool: "shell",
                                    trusted: true, userInitiated: true)
            }, approve: { s, twice in
                var ok = await self.requestApproval(ApprovalRequest(action: "shell", target: s.command, actionClass: s.actionClass,
                                                                    why: "rotina \(name): \(s.command)?"), key: nil)
                if ok, twice {
                    ok = await self.requestApproval(ApprovalRequest(action: "shell", target: s.command, actionClass: s.actionClass,
                                                                    why: "tem certeza? isto não tem volta."), key: nil)
                }
                return ok
            }, exec: { s in
                let out = try await shell.run(.object(["command": .string(s.command), "cwd": .string(ShellTool.expand(s.cwd))]))
                await self.history.append(HistoryEntry(origin: .user, summary: "rotina \(name): \(s.command)", actionClass: s.actionClass,
                                                       scope: Scope.normalize(ShellTool.expand(s.cwd)), tool: "shell",
                                                       outcome: out.isError ? .failed : .done,
                                                       trigger: "/rotina \(name)",
                                                       authorization: Authorization(.request, actionClass: s.actionClass)))
                return out
            })
            send(.taskUpdate(TaskUpdate(taskId: "rotina-\(name)", step: "feito", progress: 1, object: "diario", title: name,
                                        state: result.stoppedAt == nil ? .done : .failed, result: result.text)), to: session)
            say(result.text)
        } catch {
            say("\(error)")
        }
    }

    // MARK: - Entregas

    /// Arquivos soltos sobre o Glyph: segura uma concessão de leitura só
    /// desses caminhos e oferece ações do tipo certo.
    private func offerDelivery(_ d: InputDrop, session: Session) {
        guard delivery != nil else {
            send(.bubbleSay(BubbleSay(text: "sem casa: não posso ler.")), to: session)
            return
        }
        let items = d.paths.compactMap(DeliveredItem.classify)
        guard let offer = DeliveryActions.offer(for: items) else {
            send(.bubbleSay(BubbleSay(text: items.isEmpty ? "não achei esse arquivo." : "não sei o que fazer com isso.")), to: session)
            return
        }
        let kind = items[0].kind
        let now = Date()
        grants = grants.filter { $0.value.isValid(at: now) }
        nextOffer += 1
        let id = "e\(nextOffer)"
        grants[id] = DeliveryGrant(offerId: id, items: items.filter { $0.kind == kind }, created: now)
        log.log("entrega \(id): \(items.count) item(ns), \(kind.rawValue)")
        send(.offerActions(OfferActions(offerId: id, object: offer.object, title: offer.title,
                                        actions: offer.actions.map { OfferAction(id: $0.id, label: $0.label, sticker: $0.sticker) },
                                        timeoutSec: 120)), to: session)
    }

    private func chooseDelivery(_ c: OfferChoice, session: Session) async {
        guard let grant = grants.removeValue(forKey: c.offerId) else { return }
        guard let actionId = c.actionId else { return } // dispensou: a concessão acaba aqui
        guard grant.isValid() else {
            send(.bubbleSay(BubbleSay(text: "expirou. me entrega de novo?")), to: session)
            return
        }
        guard let delivery, let action = DeliveryActions.action(actionId),
              DeliveryActions.offer(for: grant.items)?.actions.contains(action) == true else { return }
        guard !busy else {
            grants[c.offerId] = grant
            send(.bubbleSay(BubbleSay(text: "calma, um de cada vez.")), to: session)
            return
        }
        let kind = grant.items[0].kind
        let title = DeliveryActions.offer(for: grant.items)?.title ?? "entrega"
        let cloud = action.usesBrain && DeliveryRunner.leavesMachine(agent.brain)
        var auth = Authorization(.request, actionClass: cloud ? .networkRead : .read)
        if cloud, !deliveryConsent.contains(kind) {
            // O conteúdo vai sair da máquina: a primeira vez por tipo, pergunta.
            let provider = agent.brain.id.split(separator: ":").first.map(String.init) ?? agent.brain.id
            let ok = await requestApproval(ApprovalRequest(action: "enviar_conteudo", target: "\(title) → \(provider)",
                                                           actionClass: .externalEffect,
                                                           why: "o conteúdo vai para \(provider). pode?", timeoutSec: 60), key: nil)
            guard ok else {
                await history.append(HistoryEntry(origin: .user, summary: "entregou \(title): \(action.label)", actionClass: .externalEffect,
                                                  tool: "entrega", outcome: .denied, detail: "conteúdo não enviado ao cérebro",
                                                  authorization: Authorization(.refused, actionClass: .externalEffect)))
                send(.bubbleSay(BubbleSay(text: "ok, não mando.")), to: session)
                return
            }
            deliveryConsent.insert(kind)
            auth = Authorization(.card, actionClass: .externalEffect, at: Date(), note: "conteúdo para \(provider)")
        }
        busy = true
        defer { busy = false }
        send(.bodyEmote(BodyEmote(clip: "work", dot: action.usesBrain ? .orbit : .trail)), to: session)
        let started = Date()
        let r = await delivery.run(action, grant: grant, brain: agent.brain)
        await history.append(HistoryEntry(origin: .user, summary: "entregou \(title): \(action.label)",
                                          actionClass: action.id == "referencia" ? .localWrite : (cloud ? .networkRead : .read),
                                          scope: grant.items.first.map { Scope.normalize($0.path) }, tool: "entrega",
                                          outcome: r.failed ? .failed : .done, detail: r.line, authorization: auth,
                                          cost: ActionCost(seconds: Date().timeIntervalSince(started)), evidence: r.reportPath))
        send(.bodyEmote(BodyEmote(clip: r.failed ? "error" : "idle", dot: r.failed ? .shrink : .steady)), to: session)
        if let plan = r.planID {
            send(.taskUpdate(TaskUpdate(taskId: plan, step: "ensaio pronto", progress: 0.5, object: "pasta", title: "organizar \(title)",
                                        state: .needsYou, pending: r.line)), to: session)
        } else {
            send(.taskUpdate(TaskUpdate(taskId: grant.offerId, step: action.label, progress: 1, object: "envelope",
                                        title: "\(action.label): \(title)", state: r.failed ? .failed : .done, result: r.line)), to: session)
        }
    }

    // MARK: - Agentes externos

    /// Um agente externo só anima o corpo: gesto, fala e ir até um ponto.
    /// Não pede aprovação, não mexe em tarefa, não vê o mundo, não usa os
    /// sinais de segurança. Com o freio puxado, fica mudo.
    private func externalAgentMessage(_ message: Message, session: Session) {
        switch message {
        case .hello:
            send(.hello(Hello(role: .body, capabilities: ["puppet"], name: "glyphd")), to: session)
            return
        case .bodyEmote, .bubbleSay, .bodyGoto:
            break
        default:
            log.log("agente \(session.agentName ?? "?"): \(message.kind.rawValue) não é permitido a agente externo")
            return
        }
        guard !paused else { return }
        let now = Date()
        session.recent = session.recent.filter { now.timeIntervalSince($0) < 2 } + [now]
        guard session.recent.count <= 5 else { return }
        let bodies = sessions.values.filter { $0.role == .body }
        switch message {
        case let .bodyEmote(e):
            guard !PackLoader.protectedClips.contains(e.clip), !PackLoader.protectedStickers.contains(e.sticker ?? ""),
                  e.dot != .blink, e.dot != .alert else {
                log.log("agente \(session.agentName ?? "?"): \(e.clip) é sinal de segurança")
                return
            }
            for b in bodies { send(.bodyEmote(BodyEmote(clip: e.clip, dot: e.dot, sticker: e.sticker)), to: b) }
        case let .bubbleSay(b):
            for body in bodies { send(.bubbleSay(BubbleSay(text: b.text, durationSec: min(b.durationSec, 8))), to: body) }
        case let .bodyGoto(g):
            if case .window = g.target { return } // janelas são do mundo observado: o agente não vê
            for b in bodies { send(.bodyGoto(g), to: b) }
        default:
            break
        }
    }

    // MARK: - Mensagens

    private func send(_ message: Message, to session: Session) {
        nextMessage += 1
        session.connection.send(Envelope(id: "d\(nextMessage)", message: message))
    }

    /// Manda para todos os corpos conectados.
    func broadcast(_ message: Message) {
        for s in sessions.values where s.role == .body { send(message, to: s) }
    }

    private var primary: Session? { sessions.values.filter { $0.role == .body }.min { $0.id < $1.id } }

    // MARK: - Chamado

    /// Por quanto tempo um clique explica a última ação autônoma.
    static let explainWindow: TimeInterval = 120

    private func summon(_ s: InputSummon, session: Session) async {
        if paused {
            // Chamar é um pedido explícito: solta o freio.
            await brake(false)
        }
        guard let text = s.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            send(.bodyEmote(BodyEmote(clip: "wave", dot: .pulse)), to: session)
            // Clique logo depois de uma ação autônoma: "por que você fez isso?"
            if !busy, let last = await history.recent(1).last, last.origin == .autonomous,
               Date().timeIntervalSince(last.ts) < Self.explainWindow, last.outcome != .discarded {
                send(.bubbleSay(BubbleSay(text: Explanation.short(last.why), durationSec: 8)), to: session)
                return
            }
            send(.bubbleSay(BubbleSay(text: busy ? "já tô pensando…" : "oi.")), to: session)
            return
        }
        guard !busy else {
            send(.bubbleSay(BubbleSay(text: "calma, um de cada vez.")), to: session)
            return
        }
        if await routineCommand(text, session: session) { return }
        busy = true
        let task = Task { await self.runSummon(text, session: session) }
        currentTask = task
        await task.value
        currentTask = nil
        busy = false
    }

    private func runSummon(_ text: String, session: Session) async {
        log.log("chamado: \(text)")
        let cues = ServerCues(server: self, session: session)
        var loop = agent
        loop.gate = PolicyGate(store: policy)
        loop.userInitiated = true
        do {
            let result = try await loop.run(text, context: worldContext(session.world), history: chatHistory, cues: cues)
            chatHistory = Array(result.turns.suffix(24))
            trimHistory()
            for (i, step) in result.steps.enumerated() {
                let auth: Authorization
                switch step.decision {
                case .allow, .allowAndAnnounce: auth = Authorization(.request, actionClass: step.actionClass)
                case .ask, .askTwice:
                    auth = step.approved ? Authorization(.card, actionClass: step.actionClass, at: Date())
                                         : Authorization(.refused, actionClass: step.actionClass)
                case let .deny(why): auth = Authorization(.policy, actionClass: step.actionClass, note: why)
                }
                // O custo em tokens é do chamado inteiro: vai na primeira entrada.
                let cost = i == 0 && result.usage.total > 0 ? ActionCost(tokens: result.usage.total) : nil
                let ok = step.approved && step.output?.isError == false
                let inverse = ok ? loop.tools[step.tool]?.inverse(step.input) : nil
                await history.append(HistoryEntry(origin: .user, summary: text, actionClass: step.actionClass,
                                                  tool: step.tool, outcome: step.approved ? (step.output?.isError == true ? .failed : .done) : .denied,
                                                  detail: step.output.map { String($0.text.suffix(200)) },
                                                  inverse: inverse, authorization: auth, cost: cost))
                // Trabalho de verdade deixa um objeto com o Glyph (envelope, livro, pasta…).
                if step.approved, let out = step.output, let t = loop.tools[step.tool]?.taskObject(step.input, output: out) {
                    send(.taskUpdate(t), to: session)
                }
            }
            log.log("resposta: \(result.answer) (\(result.steps.count) ferramentas, \(result.usage.total) tokens)")
            if let home = session.world?.glyph {
                send(.bodyGoto(BodyGoto(target: .point(home))), to: session)
            }
            send(.bodyEmote(BodyEmote(clip: "idle", dot: .steady)), to: session)
            send(.bubbleSay(BubbleSay(text: result.answer, durationSec: 6)), to: session)
        } catch is CancellationError {
            log.log("chamado cancelado pelo freio")
        } catch {
            log.log("erro no cérebro: \(error)")
            send(.bodyEmote(BodyEmote(clip: "error", dot: .shrink)), to: session)
            send(.bubbleSay(BubbleSay(text: Self.shortError(error))), to: session)
        }
    }

    /// O histórico precisa começar num turno do usuário com texto.
    private func trimHistory() {
        while let first = chatHistory.first {
            if case .user = first { break }
            chatHistory.removeFirst()
        }
    }

    static func shortError(_ e: Error) -> String {
        if let b = e as? BrainError {
            switch b {
            case .missingKey: return "sem chave de API."
            case let .api(status, _, _) where status == 401: return "chave de API inválida."
            case let .api(status, _, _) where status == 429: return "limite da API. já já."
            case .transport: return "sem rede?"
            default: break
            }
        }
        return "hm. deu erro."
    }

    func worldContext(_ w: WorldUpdate?) -> String {
        guard let w else { return "" }
        var lines: [String] = []
        if let app = w.activeApp { lines.append("app ativo: \(app)") }
        lines.append("usuário ocioso há \(Int(w.idleSeconds)) s; foco: \(w.focus.rawValue)")
        if let wins = w.windows, !wins.isEmpty {
            lines.append("janelas abertas: " + wins.prefix(8).map(\.app).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Freio

    /// Puxa (ou solta) o freio: pausa geral, cancela tarefas, nega aprovações
    /// pendentes, todos os Glyphs voltam para casa.
    public func brake(_ engage: Bool) async {
        guard engage != paused else { return }
        paused = engage
        if engage {
            log.log("FREIO: pausa geral")
            currentTask?.cancel()
            for (_, p) in pendingApprovals { p.continuation.resume(returning: false) }
            pendingApprovals.removeAll()
            broadcast(.bodyGoto(BodyGoto(target: .home)))
            broadcast(.bodyEmote(BodyEmote(clip: "idle", dot: .fade)))
            await history.append(HistoryEntry(origin: .user, summary: "freio puxado", outcome: .done,
                                              authorization: Authorization(.request)))
        } else {
            log.log("freio solto")
            broadcast(.bubbleSay(BubbleSay(text: "voltei.")))
        }
    }

    // MARK: - Sensores

    public func sensorEvent(_ e: SensorEvent) async {
        guard !paused else { return }
        // Um build ou teste rodando: o corpo pode explorar (só encenação).
        if let cmd = e.cmd, BuildCommands.isBuild(cmd) {
            if e.kind == "shell.start" { broadcast(.presenceHint(PresenceHint(state: .build, untilSec: 900))) }
            if e.kind == "shell.exit" { broadcast(.presenceHint(PresenceHint(state: .clear, untilSec: 1))) }
        }
        if let autonomy {
            for done in await autonomy.handle(e) {
                // O arquivo:linha que ele apontou vai para o marcador do projeto.
                if let ev = done.evidence, let scope = done.scope { await projects?.testFailure(in: scope, at: ev) }
            }
        }
        if let routines, let s = routines.record(e) {
            broadcast(.taskUpdate(TaskUpdate(taskId: "ensino-\(s.name)", step: "\(s.steps.count) anotados", progress: 0,
                                             object: "diario", title: "aprendendo \(s.name)", state: .doing)))
        }
        if let projects, let back = await projects.handle(e) {
            // Voltou a um projeto depois de um tempo: uma linha, e o marcador na mão.
            let name = (back.project as NSString).lastPathComponent
            let file = paths(projects).appendingPathComponent(name + ".md").path
            broadcast(.bubbleSay(BubbleSay(text: back.line, durationSec: 8)))
            broadcast(.taskUpdate(TaskUpdate(taskId: "projeto-\(name)", step: "retomar", progress: 0, object: "alfinete",
                                             title: name, state: .needsYou, pending: back.line, open: file)))
        }
        if let goals { await goals.trigger(e) }
    }

    private func paths(_ t: ProjectTracker) -> URL {
        t.paths.memoria.appendingPathComponent("projetos", isDirectory: true)
    }

    /// Batimento (a cada 30 s): objetivos agendados.
    public func heartbeat(now: Date = Date()) async {
        guard !paused, let goals else { return }
        let idle = primaryWorld?.idleSeconds ?? 3600
        let away = idle > 600 || sessions.isEmpty
        await goals.setNightShift(Schedule.isNight(now) || away)
        _ = await goals.heartbeat(now: now, userAway: away)
    }

    // MARK: - Aprovações

    func requestApproval(_ req: ApprovalRequest, key: TrustKey?) async -> Bool {
        guard !paused else { return false }
        let approver = sessions.values.first { $0.role == .body && ($0.trust.canApprove || options.trustUnverifiedBodies) }
        guard let approver else {
            log.log("aprovação negada: nenhum corpo verificado conectado (\(req.action) \(req.target))")
            return false
        }
        nextMessage += 1
        let id = "a\(nextMessage)"
        approver.connection.send(Envelope(id: id, message: .approvalRequest(req)))
        log.log("pedindo aprovação \(id): \(req.action) \(req.target) [\(req.actionClass.rawValue)]")
        let timeout = req.timeoutSec
        return await withCheckedContinuation { cont in
            pendingApprovals[id] = Pending(continuation: cont, key: key, tool: req.action)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: String) {
        guard let p = pendingApprovals.removeValue(forKey: id) else { return }
        log.log("aprovação \(id): sem resposta, negada")
        p.continuation.resume(returning: false)
    }

    private func resolveApproval(_ r: ApprovalResponse) async {
        guard let p = pendingApprovals.removeValue(forKey: r.requestId) else { return }
        let ok: Bool
        switch r.decision {
        case .approve:
            ok = true
        case .deny:
            ok = false
        case let .always(_, expires):
            ok = true
            // O escopo é o que o daemon guardou, não o que o corpo mandou:
            // o corpo não consegue ampliar uma regra.
            if let key = p.key {
                let until = min(expires, Date().addingTimeInterval(90 * 86_400))
                let created = await policy.allowAlways(key, tool: p.tool, until: until)
                log.log(created ? "regra criada: sempre \(key) até \(ISO8601.format(until))"
                                : "regra recusada para \(key): classe irreversível")
            }
        }
        log.log("aprovação \(r.requestId): \(ok ? "aprovada" : "negada")")
        p.continuation.resume(returning: ok)
    }

    // MARK: - Encenação

    /// Janela do app mais adequado para um lugar (navegador, terminal).
    public static func window(for place: ToolPlace, in world: WorldUpdate?) -> WindowSummary? {
        let names: [String]
        switch place {
        case .browser: names = ["Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Orion", "Chromium", "Zen"]
        case .terminal: names = ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "Alacritty", "WezTerm", "Hyper"]
        case .editor: names = ["Xcode", "Code", "Visual Studio Code", "Cursor", "Zed", "Nova", "Sublime Text"]
        case .none: return nil
        }
        return world?.windows?.first { w in names.contains { w.app.localizedCaseInsensitiveContains($0) } }
    }

    fileprivate func cue(_ message: Message, session: Session) {
        send(message, to: session)
    }

    fileprivate var primaryWorld: WorldUpdate? { primary?.world }
}

/// O servidor é o canal da autonomia com os corpos.
extension GlyphServer: BodyChannel {
    public func cue(_ message: Message) async { broadcast(message) }

    public func approve(_ request: ApprovalRequest, key: TrustKey?) async -> Bool {
        await requestApproval(request, key: key)
    }

    public func world() async -> WorldUpdate? { primaryWorld }

    public func isPaused() async -> Bool { paused }
}

/// Transforma o trabalho do agente em movimento do corpo.
struct ServerCues: AgentCues {
    let server: GlyphServer
    let session: GlyphServer.Session

    func thinking() async {
        await server.cue(.bodyEmote(BodyEmote(clip: "think", dot: .orbit)), session: session)
    }

    func willUse(tool: String, place: ToolPlace, summary: String) async {
        if let w = GlyphServer.window(for: place, in: session.world) {
            await server.cue(.bodyGoto(BodyGoto(target: .window(pid: w.pid, frame: w.frame))), session: session)
        }
        await server.cue(.bodyEmote(BodyEmote(clip: "work", dot: .trail)), session: session)
    }

    func didUse(tool: String, output: ToolOutput) async {
        if output.isError {
            await server.cue(.bodyEmote(BodyEmote(clip: "error", dot: .shrink)), session: session)
        }
    }

    func approve(action: String, target: String, actionClass: ActionClass, scope: String, why: String) async -> Bool {
        let req = ApprovalRequest(action: action, target: target, actionClass: actionClass,
                                  why: why.isEmpty ? "posso fazer isto?" : why,
                                  timeoutSec: server.options.approvalTimeout)
        return await server.requestApproval(req, key: TrustKey(actionClass, scope))
    }

    func announce(_ text: String) async {
        await server.cue(.bubbleSay(BubbleSay(text: text, durationSec: 3)), session: session)
    }
}
