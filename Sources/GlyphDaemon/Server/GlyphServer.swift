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

    private func summon(_ s: InputSummon, session: Session) async {
        if paused {
            // Chamar é um pedido explícito: solta o freio.
            await brake(false)
        }
        guard let text = s.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            send(.bodyEmote(BodyEmote(clip: "wave", dot: .pulse)), to: session)
            send(.bubbleSay(BubbleSay(text: busy ? "já tô pensando…" : "oi.")), to: session)
            return
        }
        guard !busy else {
            send(.bubbleSay(BubbleSay(text: "calma, um de cada vez.")), to: session)
            return
        }
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
            for step in result.steps {
                await history.append(HistoryEntry(origin: .user, summary: text, actionClass: step.actionClass,
                                                  tool: step.tool, outcome: step.approved ? (step.output?.isError == true ? .failed : .done) : .denied,
                                                  detail: step.output.map { String($0.text.suffix(200)) }))
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
            await history.append(HistoryEntry(origin: .user, summary: "freio puxado", outcome: .done))
        } else {
            log.log("freio solto")
            broadcast(.bubbleSay(BubbleSay(text: "voltei.")))
        }
    }

    // MARK: - Sensores

    public func sensorEvent(_ e: SensorEvent) async {
        guard !paused else { return }
        if let autonomy { await autonomy.handle(e) }
        if let goals { await goals.trigger(e) }
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
