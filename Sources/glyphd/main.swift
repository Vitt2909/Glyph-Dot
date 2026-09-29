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
        let agent = AgentLoop(brain: try Runtime.brain(config.cerebro?.principal), tools: Runtime.tools(config))
        let server = GlyphServer(options: .init(socketPath: paths.socket.path, verifier: Runtime.verifier(config),
                                                trustUnverifiedBodies: args.contains("--dev")),
                                 agent: agent, log: log)
        let started = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached {
            do { try await server.start() } catch { box.error = error }
            started.signal()
        }
        started.wait()
        if let e = box.error { fail("não consegui abrir o socket: \(e)") }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let stop: @Sendable () -> Void = {
            let done = DispatchSemaphore(value: 0)
            Task.detached { await server.stop(); done.signal() }
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
            let agent = AgentLoop(brain: try Runtime.brain(config.cerebro?.principal), tools: Runtime.tools(config))
            let result = try await agent.run(question, cues: TerminalCues(approveAll: yes))
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

/// Deixas no terminal: mostra o que o agente faz e pergunta antes de agir.
struct TerminalCues: AgentCues {
    var approveAll: Bool
    func thinking() async {}
    func willUse(tool: String, place: ToolPlace, summary: String) async {
        FileHandle.standardError.write(Data("→ \(summary)\n".utf8))
    }
    func didUse(tool: String, output: ToolOutput) async {}
    func approve(action: String, target: String, actionClass: ActionClass, why: String) async -> Bool {
        if approveAll { return true }
        FileHandle.standardError.write(Data("aprovar \(target) [\(actionClass.rawValue)]? (s/N) ".utf8))
        return readLine()?.lowercased().hasPrefix("s") == true
    }
    func announce(_ text: String) async {
        FileHandle.standardError.write(Data("· \(text)\n".utf8))
    }
}
