import Foundation
import GlyphCore
import GlyphIPC
import GlyphDaemon

// glyphd — o cérebro do Glyph.
//
// O código de topo roda no MainActor. Todo trabalho assíncrono aqui usa
// `Task.detached`: um `Task {}` comum herdaria o MainActor, que fica parado
// no `wait()` do semáforo, e o comando travaria para sempre.

let usage = """
uso: glyphd <comando>

  run [--offline] [--dev]   roda o cérebro (o LaunchAgent chama isto)
                            --offline: sem rede, cérebro de regras
                            --dev: aceita corpo não assinado para aprovar (só desenvolvimento)
  ask "pergunta" [--sim]    roda o agente uma vez no terminal (sem corpo)
                            --sim: aprova tudo que ele pedir (cuidado)
  config                    cria casa/config.yaml se não existir e mostra o caminho
  chave <anthropic|openai|brave>
                            guarda a chave de API no Keychain (lê da entrada)
  install | uninstall       liga/desliga o glyphd como LaunchAgent (macOS)
  pair <Glyph.app>          confia neste build do app (cdhash) para aprovar ações
  historico [n]             o que ele fez (sozinho ou a pedido)
  porque [id]               por que ele fez isso (a última ação, sem id)
  desfazer <id>             desfaz uma ação que tem inversa
  confianca                 escada de confiança e regras "sempre"
  ensaio <pasta>            ensaia organizar a pasta: mostra o plano, não mexe em nada
  ensaio ver <id>           mostra um plano
  ensaio decidir <id> <caso> <pular|mover|manter_ambos>
  ensaio aplicar <id> [--sim]
                            aplica o plano (pede confirmação; --sim: sem perguntar)
  ensaio desfazer <id>      desfaz o plano inteiro
  ensaios                   lista os planos
  entregas [n]              o que ele fez com arquivos que você soltou nele
  memoria [projeto]         onde cada projeto parou (fato · origem · data)
  memoria nota <projeto> "texto"
                            anota o que falta (nunca é trocado por fato automático)
  memoria apagar <projeto> <n>
                            apaga o fato n
  memoria esquecer <projeto>
                            apaga o marcador inteiro
  objetivos                 valida e lista o casa/goals.yaml
  quadro                    tarefas dos objetivos e tentativas
  quadro estacionar <id>    guarda a tarefa na prateleira (ninguém mexe nela)
  quadro retomar <id>       tira da prateleira
  diario                    escreve o diário das últimas 24 h agora
  mcp                       conecta nos servidores MCP do config e lista as ferramentas
  packs [validar <pasta>]   lista os packs da comunidade (ou valida um pack)
  mala exportar <arquivo>   leva objetivos, habilidades, memória, packs e config
  mala importar <arquivo>   traz uma mala (nunca sobrescreve: cria .da-mala)
  status                    diz se o glyphd está respondendo
  paths                     mostra onde fica a casa
  mock [--fast] [--loop]    imprime o roteiro do cérebro falso (JSON por linha)
  validate                  valida JSON por linha vindo da entrada
  version
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
let paths = GlyphPaths.standard()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadConfig() -> DaemonConfig {
    do { return try DaemonConfig.load(paths.config) } catch { fail("config.yaml inválido: \(error)") }
}

/// Espera um trabalho assíncrono no código de linha de comando.
func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value!
}

final class ResultBox<T>: @unchecked Sendable { var value: T? }

func makeLog(echo: Bool = true) -> DaemonLog {
    DaemonLog(dir: paths.logs, redactor: Redactor(secrets: Runtime.knownSecrets()), echo: echo)
}

switch command {
case "version", "--version", "-v":
    print("glyphd \(GlyphInfo.version) (protocolo v\(GlyphProtocol.version))")

case "paths":
    print("suporte: \(paths.support.path)")
    print("socket:  \(paths.socket.path)")
    print("casa:    \(paths.casa.path)")
    print("config:  \(paths.config.path)")
    print("logs:    \(paths.logs.path)")

case "config":
    do {
        try paths.ensureCasa()
        if !FileManager.default.fileExists(atPath: paths.config.path) {
            try DaemonConfig.template.write(to: paths.config, atomically: true, encoding: .utf8)
            print("criado: \(paths.config.path)")
        } else {
            _ = loadConfig()
            print("ok: \(paths.config.path)")
        }
    } catch {
        fail("erro: \(error)")
    }

case "run":
    do {
        try paths.ensureCasa()
        var config = loadConfig()
        if args.contains("--offline") {
            var c = config.cerebro ?? DaemonConfig.Cerebro()
            c.principal = DaemonConfig.BrainConfig(provider: "offline")
            config.cerebro = c
        }
        let log = makeLog()
        var tools = Runtime.tools(config)
        let frozen = config
        let mcp = blocking { await Runtime.mcpTools(frozen) }
        for t in mcp.tools { tools.add(t) }
        for e in mcp.errors { log.log("mcp: \(e)") }
        if !mcp.tools.isEmpty { log.log("mcp: \(mcp.tools.count) ferramentas de \(mcp.clients.count) servidores") }
        let mainBrain = try Runtime.brain(config.cerebro?.principal)
        var roleBrains: [SpecialistRole: any Brain] = [:]
        for (name, cfg) in config.equipe?.cerebros ?? [:] {
            if let role = SpecialistRole(rawValue: name) { roleBrains[role] = try Runtime.brain(cfg) }
        }
        let teamOn = config.equipe?.ativa ?? true
        let policy = PolicyStore(policyURL: paths.policy, trustURL: paths.trust)
        let history = HistoryStore(url: paths.history)
        let sensorPath = (config.sensores?.terminal ?? true) ? paths.sensorSocket.path : nil
        let serverBox = ServerBox()
        let team = Team(brainFor: { [roleBrains] role in roleBrains[role] ?? mainBrain }, policy: policy, history: history,
                        body: ForwardingBody(box: serverBox), log: log)
        if teamOn { tools.add(DelegateTool(team: team)) }
        let agent = AgentLoop(brain: mainBrain, tools: tools)
        let server = GlyphServer(options: .init(socketPath: paths.socket.path, sensorSocketPath: sensorPath,
                                                verifier: Runtime.verifier(config),
                                                trustUnverifiedBodies: args.contains("--dev"),
                                                allowExternalAgents: config.agentes_externos?.corpo ?? false),
                                 agent: agent, log: log, policy: policy, history: history)
        serverBox.server = server
        let repos = config.sensores?.repos ?? []
        let autonomy = AutonomyEngine(tools: tools, policy: policy, history: history,
                                      context: Reflexes.Context(watched: repos), body: server, log: log)
        let board = BoardStore(url: paths.board)
        let goalsURL = paths.goals
        let goalRunner = GoalRunner(paths: paths, brain: agent.brain, policy: policy, history: history, board: board,
                                    body: server, log: log, goals: {
            // Relido a cada uso: editar o goals.yaml vale na hora.
            let text = (try? String(contentsOf: goalsURL, encoding: .utf8)) ?? ""
            return Goal.load(yaml: text).goals
        })
        let power = NightPower()
        let keepAwake = config.turno_noturno?.manter_acordado ?? false
        let started = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached {
            do {
                try await server.start()
                await server.attach(autonomy: autonomy)
                await server.attach(goals: goalRunner)
                await server.attach(delivery: DeliveryRunner(paths: paths))
                await server.attach(projects: ProjectTracker(repos: repos, paths: paths))
                if teamOn { await goalRunner.setTeam(team) }
                await server.attach(task: Task {
                    while !Task.isCancelled {
                        let open = await board.tasks.contains { $0.isOpen }
                        if keepAwake && open { _ = power.hold() } else { power.release() }
                        await server.heartbeat()
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                    }
                })
                if !repos.isEmpty {
                    let watcher = GitWatcher(repos: repos, interval: config.sensores?.git_intervalo ?? 20) { e in
                        await server.sensorEvent(e)
                    }
                    await watcher.start()
                    await server.attach(task: Task { _ = watcher })
                }
            } catch { box.error = error }
            started.signal()
        }
        started.wait()
        if let e = box.error { fail("não consegui abrir o socket: \(e)") }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let stop: @Sendable () -> Void = {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await server.stop()
                for c in mcp.clients { await c.stop() }
                if let ext = mainBrain as? ExternalAgentBrain { await ext.stop() }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: stop)
            s.resume()
            return s
        }
        _ = sources
        dispatchMain()
    } catch {
        fail("erro: \(error)")
    }

case "ask":
    let yes = args.contains("--sim")
    let question = args.filter { !$0.hasPrefix("--") }.joined(separator: " ")
    guard !question.isEmpty else { fail("uso: glyphd ask \"pergunta\"") }
    let config = loadConfig()
    let log = makeLog(echo: false)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            var tools = Runtime.tools(config)
            let mcp = await Runtime.mcpTools(config)
            for t in mcp.tools { tools.add(t) }
            for e in mcp.errors { FileHandle.standardError.write(Data("mcp: \(e)\n".utf8)) }
            let brain = try Runtime.brain(config.cerebro?.principal)
            let agent = AgentLoop(brain: brain, tools: tools)
            let result = try await agent.run(question, cues: TerminalCues(approveAll: yes))
            for c in mcp.clients { await c.stop() }
            if let ext = brain as? ExternalAgentBrain { await ext.stop() }
            for s in result.steps {
                print("· \(s.tool) [\(s.actionClass.rawValue)] \(s.approved ? "" : "(negado)")")
            }
            print(result.answer)
            log.log("ask: \(question) → \(result.answer)")
        } catch {
            FileHandle.standardError.write(Data("erro: \(error)\n".utf8))
        }
        done.signal()
    }
    done.wait()

case "chave":
    guard let provider = args.first, ["anthropic", "openai", "brave"].contains(provider) else {
        fail("uso: glyphd chave <anthropic|openai|brave>")
    }
    FileHandle.standardError.write(Data("cole a chave de \(provider) e tecle Enter: ".utf8))
    guard let key = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { fail("vazio") }
    do { try SecretStore.set(provider, key); print("guardada no Keychain.") } catch { fail("\(error)") }

case "install":
    #if os(macOS)
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    do {
        try paths.ensureCasa()
        try LaunchAgent(executable: exe, logDir: paths.logs.path).install()
        print("glyphd instalado como LaunchAgent (\(LaunchAgent.label)).")
    } catch { fail("erro: \(error)") }
    #else
    fail("LaunchAgent só existe no macOS. No Linux, rode `glyphd run` (ou um serviço systemd de usuário).")
    #endif

case "uninstall":
    #if os(macOS)
    LaunchAgent.uninstall()
    print("glyphd removido dos LaunchAgents.")
    #else
    fail("só no macOS")
    #endif

case "pair":
    #if canImport(Security)
    guard let app = args.first else { fail("uso: glyphd pair /caminho/Glyph.app") }
    guard let hash = CodeSignature.cdhash(ofAppAt: URL(fileURLWithPath: app)) else { fail("não consegui ler a assinatura de \(app)") }
    print("cdhash: \(hash)")
    print("Adicione em \(paths.config.path):\n  corpo:\n    pareados: [\(hash)]")
    #else
    fail("pareamento por assinatura só no macOS")
    #endif

case "historico":
    let n = Int(args.first ?? "") ?? 20
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for e in await HistoryStore(url: paths.history).recent(n) {
            let when = String(ISO8601.format(e.ts).prefix(16)).replacingOccurrences(of: "T", with: " ")
            let cls = e.actionClass.map { " [\($0.rawValue)]" } ?? ""
            let who = e.origin == .autonomous ? "sozinho" : "pedido"
            print("\(e.id)  \(when)  \(who)  \(e.outcome.rawValue)\(cls)  \(e.summary)\(e.detail.map { " — \($0)" } ?? "")\(e.inverse != nil ? "  (desfazível)" : "")")
        }
        done.signal()
    }
    done.wait()

case "porque":
    let wanted = args.first
    let lines: [String] = blocking {
        let h = HistoryStore(url: paths.history)
        let e: HistoryEntry?
        if let wanted { e = await h.entry(wanted) } else { e = await h.recent(1).last }
        guard let e else { return [] }
        let when = String(ISO8601.format(e.ts).prefix(16)).replacingOccurrences(of: "T", with: " ")
        return ["\(e.id)  \(when)"] + Explanation.lines(e.why).map { "  " + $0 }
    }
    if lines.isEmpty { fail(wanted.map { "não achei \($0)" } ?? "histórico vazio") }
    lines.forEach { print($0) }

case "desfazer":
    guard let id = args.first else { fail("uso: glyphd desfazer <id>") }
    let config = loadConfig()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let history = HistoryStore(url: paths.history)
        let policy = PolicyStore(policyURL: paths.policy, trustURL: paths.trust)
        guard let e = await history.entry(id) else { print("não achei \(id)"); done.signal(); return }
        guard let inv = e.inverse, let tool = Runtime.tools(config)[inv.tool] else {
            print("\(id) não tem como desfazer"); done.signal(); return
        }
        do {
            let out = try await tool.run(inv.input)
            print(out.isError ? "desfazer falhou: \(out.text)" : "desfeito: \(inv.summary)")
            if !out.isError {
                if let c = e.actionClass, let s = e.scope { await policy.recordUndo(TrustKey(c, s)) }
                await history.append(HistoryEntry(origin: .user, summary: "desfazer \(id): \(inv.summary)", outcome: .undone))
            }
        } catch { print("erro: \(error)") }
        done.signal()
    }
    done.wait()

case "memoria":
    let config = loadConfig()
    let tracker = ProjectTracker(repos: config.sensores?.repos ?? [], paths: paths)
    let sub = args.first
    func show(_ m: ProjectMarker) {
        print("\(m.name)  (\(m.root))")
        for (i, f) in m.facts.enumerated() { print("  \(i + 1). \(f.kind.rawValue): \(f.text) · \(f.origin)") }
        if let l = m.resumeLine { print("  → \(l)") }
    }
    func find(_ name: String) -> ProjectMarker {
        let all = blocking { await tracker.all() }
        guard let m = all.first(where: { $0.name == name }) else {
            fail("projeto \(name) não está em sensores.repos (\(all.map(\.name).joined(separator: ", ")))")
        }
        return m
    }
    switch sub {
    case nil:
        let all = blocking { await tracker.all() }
        if all.isEmpty { print("nenhum projeto: marque pastas em sensores.repos no config.yaml") }
        all.forEach(show)
    case "nota"?:
        guard args.count >= 3 else { fail("uso: glyphd memoria nota <projeto> \"texto\"") }
        let m = find(args[1])
        let text = args[2...].joined(separator: " ")
        if let updated = blocking({ await tracker.note(m.name, text) }) { show(updated) }
    case "apagar"?:
        guard args.count >= 3, let n = Int(args[2]) else { fail("uso: glyphd memoria apagar <projeto> <n>") }
        var m = find(args[1])
        guard n >= 1, n <= m.facts.count else { fail("não há fato \(n)") }
        m.facts.remove(at: n - 1)
        let edited = m
        blocking { await tracker.save(edited) }
        show(m)
    case "esquecer"?:
        guard args.count >= 2 else { fail("uso: glyphd memoria esquecer <projeto>") }
        let m = find(args[1])
        let url = paths.memoria.appendingPathComponent("projetos/\(m.name).md")
        try? FileManager.default.removeItem(at: url)
        print("esqueci \(m.name).")
    case let name?:
        show(find(name))
    }

case "entregas":
    let n = Int(args.first ?? "") ?? 10
    let dir = paths.entregas
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    if files.isEmpty { print("nenhuma entrega ainda") }
    for f in files.suffix(n).reversed() {
        let first = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8))?.split(separator: "\n").first ?? ""
        print("\(dir.appendingPathComponent(f).path)\n    \(first.replacingOccurrences(of: "# ", with: ""))")
    }

case "ensaios":
    for p in RehearsalStore(paths: paths).list() {
        print("\(p.id)  \(p.status.rawValue)  \(p.title): \(p.summary)")
    }

case "ensaio":
    let store = RehearsalStore(paths: paths)
    let sub = args.first ?? ""
    func show(_ p: RehearsalPlan) { p.preview(limit: 60).forEach { print($0) } }
    do {
        switch sub {
        case "ver":
            guard args.count >= 2 else { fail("uso: glyphd ensaio ver <id>") }
            show(try store.load(args[1]))
        case "decidir":
            guard args.count >= 4, let choice = PlanDecision.Choice(rawValue: args[3]) else {
                fail("uso: glyphd ensaio decidir <id> <caso> <pular|mover|manter_ambos>")
            }
            show(try store.decide(args[1], decision: args[2], choice: choice))
        case "aplicar":
            guard args.count >= 2 else { fail("uso: glyphd ensaio aplicar <id> [--sim]") }
            let plan = try store.load(args[1])
            show(plan)
            if !plan.pendingDecisions.isEmpty {
                print("\(plan.pendingDecisions.count) caso(s) sem decisão ficam como estão.")
            }
            if !args.contains("--sim") {
                FileHandle.standardError.write(Data("aplicar? (s/N) ".utf8))
                guard readLine()?.lowercased().hasPrefix("s") == true else { fail("nada feito.") }
            }
            let id = plan.id
            let r = try blocking { () -> Result<RehearsalStore.ApplyResult, Error> in
                do { return .success(try await store.apply(id)) } catch { return .failure(error) }
            }.get()
            print(r.text)
            r.skipped.forEach { print("  - " + $0) }
            blocking {
                _ = await HistoryStore(url: paths.history).append(HistoryEntry(
                    origin: .user, summary: "\(plan.title) (plano \(id))", actionClass: .localWrite, scope: plan.root,
                    tool: "aplicar_plano", outcome: .done, detail: r.text,
                    inverse: HistoryEntry.Inverse(tool: "desfazer_plano", input: .object(["plano": .string(id)]), summary: "desfazer o plano \(id)"),
                    authorization: Authorization(.plan, actionClass: .localWrite, scope: plan.root, at: Date(), ref: id)))
            }
        case "desfazer":
            guard args.count >= 2 else { fail("uso: glyphd ensaio desfazer <id>") }
            let r = try store.undo(args[1])
            print(r.text)
            r.skipped.forEach { print("  - " + $0) }
            let summary = "desfazer o plano \(args[1])"
            blocking { _ = await HistoryStore(url: paths.history).append(HistoryEntry(origin: .user, summary: summary, outcome: .undone,
                                                                                     authorization: Authorization(.request))) }
        case "":
            fail("uso: glyphd ensaio <pasta>")
        default:
            let config = loadConfig()
            let scope = RehearsalScope(folders: config.ferramentas?.organizar?.pastas ?? ["~/Downloads"])
            guard scope.allows(sub) else {
                fail("só organizo \(scope.folders.map(Explanation.shortPath).joined(separator: ", ")) (ferramentas.organizar.pastas no config.yaml)")
            }
            let plan = try store.prepare(folder: sub)
            show(plan)
            print("\nnada foi mexido. para aplicar: glyphd ensaio aplicar \(plan.id)")
        }
    } catch {
        fail("\(error)")
    }

case "confianca":
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let p = await PolicyStore(policyURL: paths.policy, trustURL: paths.trust).policy
        print("níveis: 0 observar · 1 sugerir · 2 agir e avisar · 3 agir em silêncio")
        if p.ladder.records.isEmpty { print("(tudo nos níveis iniciais)") }
        for (k, r) in p.ladder.records.sorted(by: { $0.key < $1.key }) {
            print("\(k): \(r.level.rawValue) (\(r.level)); sequência \(r.streak)")
        }
        print("regras \"sempre\": \(p.rules.count)")
        for r in p.rules { print("  \(r.classe.rawValue) em \(r.escopo)\(r.acao.map { " (\($0))" } ?? "") até \(ISO8601.format(r.expira))") }
        done.signal()
    }
    done.wait()

case "objetivos":
    let text = (try? String(contentsOf: paths.goals, encoding: .utf8)) ?? ""
    let (goals, errors) = Goal.load(yaml: text)
    if goals.isEmpty && errors.isEmpty { print("nenhum objetivo em \(paths.goals.path)") }
    for g in goals {
        let classes = g.allowedClasses.map(\.rawValue).sorted().joined(separator: ", ")
        print("\(g.id): \(g.descricao)\n  escopo \(g.escopo ?? "-") · horário \(g.horario ?? "sempre") · classes [\(classes)]")
    }
    for e in errors { print("ERRO: \(e)") }
    exit(errors.isEmpty ? 0 : 1)

case "quadro" where ["estacionar", "retomar"].contains(args.first ?? ""):
    guard args.count >= 2 else { fail("uso: glyphd quadro \(args[0]) <id>") }
    let park = args[0] == "estacionar", id = args[1]
    let t: BoardTask? = blocking {
        guard let t = await BoardStore(url: paths.board).shelf(id, park: park) else { return nil }
        await HistoryStore(url: paths.history).append(HistoryEntry(origin: .user, summary: "\(park ? "estacionou" : "retomou") \(t.title)",
                                                                   outcome: .done, authorization: Authorization(.request)))
        return t
    }
    guard let t else { fail("não dá: \(id) não existe ou já está \(park ? "fechada ou na prateleira" : "fora da prateleira")") }
    print("[\(t.status.rawValue)] \(t.title)")

case "quadro":
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let tasks = await BoardStore(url: paths.board).tasks
        if tasks.isEmpty { print("quadro vazio") }
        for t in tasks.suffix(30) {
            print("\(t.id)  [\(t.status.rawValue)] \(t.title)\(t.branch.map { " (\($0))" } ?? "")")
            for (i, a) in t.attempts.enumerated() { print("    \(i + 1). \(a.success ? "✓" : "✗") \(a.hypothesis)") }
            if let n = t.note { print("    \(n)") }
        }
        done.signal()
    }
    done.wait()

case "diario":
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let url = await GoalRunner(paths: paths, brain: OfflineBrain(), policy: PolicyStore(policyURL: nil, trustURL: nil),
                                   history: HistoryStore(url: paths.history), board: BoardStore(url: paths.board),
                                   body: NoBody(), log: makeLog(echo: false), goals: { [] }).writeDiary()
        print(url.path)
        done.signal()
    }
    done.wait()

case "mcp":
    let config = loadConfig()
    guard !(config.mcp ?? []).isEmpty else {
        print("nenhum servidor MCP no config.yaml (seção mcp:)")
        exit(0)
    }
    let r = blocking { await Runtime.mcpTools(config) }
    for t in r.tools.sorted(by: { $0.spec.name < $1.spec.name }) {
        let origin = t.declaredClass == nil ? "padrão: sempre pede" : "declarada no config"
        print("\(t.spec.name)  [\(t.actionClass.rawValue), \(origin)]")
    }
    for e in r.errors { print("ERRO \(e)") }
    blocking { for c in r.clients { await c.stop() } }
    exit(r.errors.isEmpty ? 0 : 1)

case "packs":
    if args.first == "validar" {
        guard args.count >= 2 else { fail("uso: glyphd packs validar <pasta>") }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        let p = PackLoader.loadPack(dir, requireManifest: true)
        var problems = p.errors
        for id in p.clips.clips.keys where PackLoader.protectedClips.contains(id) {
            problems.append("clipe \(id) é sinal de segurança: será ignorado")
        }
        for id in p.stickers.keys where PackLoader.protectedStickers.contains(id) {
            problems.append("sticker \(id) é sinal de segurança: será ignorado")
        }
        if let m = p.manifest {
            print("\(m.nome) \(m.versao) por \(m.autor) (\(m.licenca)): \(p.clips.clips.count) clipes, \(p.stickers.count) stickers")
        }
        for e in problems { print("· \(e)") }
        exit(problems.isEmpty && p.manifest != nil ? 0 : 1)
    }
    let dirs = PackLoader.communityPacks(in: paths.packs)
    if dirs.isEmpty { print("nenhum pack da comunidade em \(paths.packs.path)") }
    for d in dirs {
        let p = PackLoader.loadPack(d, requireManifest: true)
        if let m = p.manifest {
            print("\(m.id): \(m.nome) \(m.versao) por \(m.autor) (\(m.licenca)) — \(p.clips.clips.count) clipes, \(p.stickers.count) stickers")
        }
        for e in p.errors { print("  · \(e)") }
    }

case "mala":
    guard args.count >= 2 else { fail("uso: glyphd mala exportar|importar <arquivo>") }
    let file = URL(fileURLWithPath: args[1])
    do {
        switch args[0] {
        case "exportar":
            let files = try Mala.export(casa: paths.casa, to: file)
            print("mala pronta: \(file.path) (\(files.count) arquivos)")
            print("fica em casa: confiança, regras \"sempre\", histórico, diário, quadro e chaves.")
        case "importar":
            try paths.ensureCasa()
            let r = try Mala.importBundle(file, into: paths.casa)
            for f in r.written { print("+ \(f)") }
            for f in r.conflicts { print("≠ \(f) (já existia: a versão da mala está em \(f).da-mala)") }
            for f in r.skipped { print("✗ \(f)") }
            print("a confiança começa do zero nesta máquina.")
        default:
            fail("uso: glyphd mala exportar|importar <arquivo>")
        }
    } catch {
        fail("erro: \(error)")
    }

case "status":
    do {
        let conn = try UnixSocketClient.connect(path: paths.socket.path)
        conn.close()
        print("glyphd está rodando (\(paths.socket.path))")
    } catch {
        print("glyphd não está rodando: \(error)")
        exit(1)
    }

case "mock":
    do {
        if args.contains("--fast") {
            for line in try MockStream().allLines() { print(line, terminator: "") }
        } else {
            try MockStream(loops: args.contains("--loop")).run { FileHandle.standardOutput.write(Data($0.utf8)) }
        }
    } catch {
        fail("erro: \(error)")
    }

case "validate":
    let codec = LineCodec()
    var failures = 0
    var lineNo = 0
    while let line = readLine() {
        lineNo += 1
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        do {
            let env = try codec.decode(line)
            let sender: Peer = Message.Kind(rawValue: env.type)?.allowedSenders.contains(.brain) == true ? .brain : .body
            try ProtocolValidator.validate(env, from: sender)
            print("ok \(lineNo): \(env.type)")
        } catch {
            failures += 1
            print("ERRO \(lineNo): \(error)")
        }
    }
    exit(failures == 0 ? 0 : 1)

case "help", "--help", "-h":
    print(usage)

default:
    fail("comando desconhecido: \(command)\n\n\(usage)")
}

final class ErrorBox: @unchecked Sendable { var error: Error? }

/// O time é criado antes do servidor; esta caixa liga os dois.
final class ServerBox: @unchecked Sendable { var server: GlyphServer? }

struct ForwardingBody: BodyChannel {
    let box: ServerBox
    func cue(_ message: Message) async { await box.server?.cue(message) }
    func approve(_ request: ApprovalRequest, key: TrustKey?) async -> Bool { await box.server?.approve(request, key: key) ?? false }
    func world() async -> WorldUpdate? { await box.server?.world() }
    func isPaused() async -> Bool { await box.server?.isPaused() ?? false }
}

/// Sem corpo (comandos de terminal).
struct NoBody: BodyChannel {
    func cue(_ message: Message) async {}
    func approve(_ request: ApprovalRequest, key: TrustKey?) async -> Bool { false }
    func world() async -> WorldUpdate? { nil }
    func isPaused() async -> Bool { false }
}

/// Deixas no terminal: mostra o que o agente faz e pergunta antes de agir.
struct TerminalCues: AgentCues {
    var approveAll: Bool
    func thinking() async {}
    func willUse(tool: String, place: ToolPlace, summary: String) async {
        FileHandle.standardError.write(Data("→ \(summary)\n".utf8))
    }
    func didUse(tool: String, output: ToolOutput) async {}
    func approve(action: String, target: String, actionClass: ActionClass, scope: String, why: String) async -> Bool {
        if approveAll { return true }
        FileHandle.standardError.write(Data("aprovar \(target) [\(actionClass.rawValue)]? (s/N) ".utf8))
        return readLine()?.lowercased().hasPrefix("s") == true
    }
    func announce(_ text: String) async {
        FileHandle.standardError.write(Data("· \(text)\n".utf8))
    }
}
