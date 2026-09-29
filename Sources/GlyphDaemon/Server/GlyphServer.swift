import Foundation
import GlyphCore
import GlyphIPC

/// O `glyphd` em execução: aceita corpos no socket, conversa com eles pelo
/// Glyph Protocol e roda o cérebro quando o usuário chama.
///
/// Nunca executa nada a pedido do corpo: o corpo só percebe e aprova. Toda
/// ação passa pelo `ActionGate` dentro do `AgentLoop`.
public actor GlyphServer {
    public struct Options: Sendable {
        public var socketPath: String
        public var verifier: PeerVerifier
        /// Deixe corpos não verificados aprovarem. Só para desenvolvimento.
        public var trustUnverifiedBodies: Bool
        public var approvalTimeout: Double

        public init(socketPath: String, verifier: PeerVerifier = PeerVerifier(), trustUnverifiedBodies: Bool = false,
                    approvalTimeout: Double = 120) {
            self.socketPath = socketPath
            self.verifier = verifier
            self.trustUnverifiedBodies = trustUnverifiedBodies
            self.approvalTimeout = approvalTimeout
        }
    }

    final class Session: @unchecked Sendable {
        let id: Int
        let connection: LineConnection
        let trust: PeerTrust
        var world: WorldUpdate?
        var greeted = false

        init(id: Int, connection: LineConnection, trust: PeerTrust) {
            self.id = id
            self.connection = connection
            self.trust = trust
        }
    }

    public let options: Options
    private var agent: AgentLoop
    private let log: DaemonLog
    private var server: UnixSocketServer?
    private var sessions: [Int: Session] = [:]
    private var nextSession = 0
    private var nextMessage = 0
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var busy = false
    private var history: [ChatTurn] = []

    public init(options: Options, agent: AgentLoop, log: DaemonLog) {
        self.options = options
        self.agent = agent
        self.log = log
    }

    public func start() throws {
        let s = UnixSocketServer(path: options.socketPath)
        s.onConnection = { [weak self] conn in
            guard let self else { return }
            Task { await self.accept(conn) }
        }
        try s.start()
        server = s
        log.log("glyphd ouvindo em \(options.socketPath) (cérebro: \(agent.brain.id))")
    }

    public func stop() {
        server?.stop()
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
        do {
            try ProtocolValidator.validate(env, from: .body)
        } catch {
            log.log("corpo \(id): \(error)")
            return
        }
        switch env.message {
        case .hello:
            session.greeted = true
            send(.hello(Hello(role: .brain, capabilities: ["agent", "tools"], name: "glyphd")), to: session)
        case let .worldUpdate(w):
            session.world = w
        case let .inputSummon(s):
            await summon(s, session: session)
        case let .approvalResponse(r):
            guard session.trust.canApprove || options.trustUnverifiedBodies else {
                log.log("corpo \(id) tentou aprovar sem assinatura conferida: ignorado")
                return
            }
            resolveApproval(r)
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
        for s in sessions.values { send(message, to: s) }
    }

    private var primary: Session? { sessions.values.min { $0.id < $1.id } }

    // MARK: - Chamado

    private func summon(_ s: InputSummon, session: Session) async {
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
        defer { busy = false }
        log.log("chamado: \(text)")
        let cues = ServerCues(server: self, session: session)
        do {
            let result = try await agent.run(text, context: worldContext(session.world), history: history, cues: cues)
            history = Array(result.turns.suffix(24))
            trimHistory()
            log.log("resposta: \(result.answer) (\(result.steps.count) ferramentas, \(result.usage.total) tokens)")
            if let home = session.world?.glyph {
                send(.bodyGoto(BodyGoto(target: .point(home))), to: session)
            }
            send(.bodyEmote(BodyEmote(clip: "idle", dot: .steady)), to: session)
            send(.bubbleSay(BubbleSay(text: result.answer, durationSec: 6)), to: session)
        } catch {
            log.log("erro no cérebro: \(error)")
            send(.bodyEmote(BodyEmote(clip: "error", dot: .shrink)), to: session)
            send(.bubbleSay(BubbleSay(text: Self.shortError(error))), to: session)
        }
    }

    /// O histórico precisa começar num turno do usuário com texto (não com
    /// resultados de ferramentas soltos).
    private func trimHistory() {
        while let first = history.first {
            if case .user = first { break }
            history.removeFirst()
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

    // MARK: - Aprovações

    func requestApproval(_ req: ApprovalRequest, session: Session) async -> Bool {
        let approver = sessions.values.first { $0.trust.canApprove || options.trustUnverifiedBodies }
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
            pendingApprovals[id] = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: String) {
        guard let cont = pendingApprovals.removeValue(forKey: id) else { return }
        log.log("aprovação \(id): sem resposta, negada")
        cont.resume(returning: false)
    }

    private func resolveApproval(_ r: ApprovalResponse) {
        guard let cont = pendingApprovals.removeValue(forKey: r.requestId) else { return }
        let ok: Bool
        switch r.decision {
        case .approve, .always: ok = true
        case .deny: ok = false
        }
        log.log("aprovação \(r.requestId): \(ok ? "aprovada" : "negada")")
        cont.resume(returning: ok)
    }

    // MARK: - Encenação

    /// Janela do app mais adequado para um lugar (navegador, terminal).
    static func window(for place: ToolPlace, in world: WorldUpdate?) -> WindowSummary? {
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

    func approve(action: String, target: String, actionClass: ActionClass, why: String) async -> Bool {
        let req = ApprovalRequest(action: action, target: target, actionClass: actionClass,
                                  why: why.isEmpty ? "posso fazer isto?" : why,
                                  timeoutSec: server.options.approvalTimeout)
        return await server.requestApproval(req, session: session)
    }

    func announce(_ text: String) async {
        await server.cue(.bubbleSay(BubbleSay(text: text, durationSec: 3)), session: session)
    }
}
