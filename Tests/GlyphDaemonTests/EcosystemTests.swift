import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

/// M6: agentes externos, MCP e a mala.
final class EcosystemTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eco-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - MCP

    /// Servidor MCP falso em sh: responde initialize, tools/list e tools/call,
    /// mistura log solto, notificação e um pedido do servidor para o cliente.
    static let fakeMCP = #"""
    echo "servidor falso iniciando"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"falso","version":"1"}}}\n' "$id" ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"oi"}}\n'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"eco","description":"Repete o texto","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"apaga tudo","description":"x","inputSchema":{"type":"string"}}]}}\n' "$id" ;;
        *'"method":"tools/call"'*)
          if [ -n "$FAKE_HANG" ]; then continue; fi
          printf '{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage","params":{}}\n'
          text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"eco: %s"}],"isError":false}}\n' "$id" "$text" ;;
      esac
    done
    """#

    func testMCPListsAndCallsTools() async throws {
        let path = try script("mcp.sh", Self.fakeMCP)
        let client = MCPClient(name: "falso", command: [path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        let infos = try await client.listTools()
        XCTAssertEqual(infos.map(\.name), ["eco", "apaga tudo"])
        let r = try await client.call("eco", arguments: .object(["text": .string("ola")]))
        XCTAssertEqual(r.text, "eco: ola")
        XCTAssertFalse(r.isError)
        // Segunda chamada no mesmo processo.
        let r2 = try await client.call("eco", arguments: .object(["text": .string("de novo")]))
        XCTAssertEqual(r2.text, "eco: de novo")
        await client.stop()
    }

    func testMCPToolDefaultsToExternalEffectAndIgnoresServerHints() async throws {
        let path = try script("mcp.sh", Self.fakeMCP)
        let client = MCPClient(name: "falso", command: [path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        let infos = try await client.listTools()
        let eco = MCPTool(server: "falso", info: infos[0], declaredClass: nil, client: client)
        XCTAssertEqual(eco.actionClass, .externalEffect, "readOnlyHint do servidor não vale")
        XCTAssertEqual(eco.actionClass.isReversible, false)
        XCTAssertEqual(eco.spec.name, "mcp__falso__eco")
        XCTAssertTrue(eco.spec.description.hasPrefix("[MCP falso]"))
        let weird = MCPTool(server: "falso", info: infos[1], declaredClass: nil, client: client)
        XCTAssertEqual(weird.spec.name, "mcp__falso__apaga_tudo")
        XCTAssertEqual(weird.spec.inputSchema["type"]?.stringValue, "object")
        // O usuário pode declarar a classe no config.
        let declared = MCPTool(server: "falso", info: infos[0], declaredClass: .read, client: client)
        XCTAssertEqual(declared.actionClass, .read)
        // A saída é conteúdo observado.
        let out = try await declared.run(.object(["text": .string("x")]))
        XCTAssertTrue(out.untrusted)
        XCTAssertTrue(out.text.contains("<conteudo_observado fonte=\"mcp:falso\">"))
        await client.stop()
    }

    func testMCPToolNeedsApprovalInTheAgentLoop() async throws {
        let path = try script("mcp.sh", Self.fakeMCP)
        let client = MCPClient(name: "falso", command: [path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        let infos = try await client.listTools()
        let eco = MCPTool(server: "falso", info: infos[0], declaredClass: nil, client: client)
        let brain = ScriptedBrain(replies: [toolUse("mcp__falso__eco", ["text": .string("oi")]), BrainReply(text: "ok")])
        let r = try await AgentLoop(brain: brain, tools: ToolRegistry([eco])).run("usa", cues: SilentCues(approveAll: false))
        XCTAssertEqual(r.steps.first?.decision, .ask)
        XCTAssertEqual(r.steps.first?.approved, false)
        XCTAssertNil(r.steps.first?.output, "sem aprovação, não chama o servidor")
        await client.stop()
    }

    func testMCPTimeoutKillsHungServer() async throws {
        let path = try script("mcp.sh", Self.fakeMCP)
        let client = MCPClient(name: "falso", command: [path], environment: ["PATH": "/usr/bin:/bin", "FAKE_HANG": "1"], timeout: 1)
        _ = try await client.listTools()
        let start = Date()
        do {
            _ = try await client.call("eco", arguments: .object([:]))
            XCTFail("devia estourar o tempo")
        } catch let e as MCPError {
            XCTAssertEqual(e, .timeout("tools/call"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        await client.stop()
    }

    func testMCPMissingServerIsAnError() async throws {
        var cfg = DaemonConfig()
        cfg.mcp = [DaemonConfig.MCPServer(nome: "sumido", comando: ["/nao/existe/servidor"], env: nil, classes: nil, timeout: 2, ativo: nil),
                   DaemonConfig.MCPServer(nome: "desligado", comando: ["/nao/existe"], env: nil, classes: nil, timeout: 2, ativo: false)]
        let r = await Runtime.mcpTools(cfg)
        XCTAssertTrue(r.tools.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].hasPrefix("sumido:"))
    }

    func testMCPConfigParsesClassesAndEnvReferences() throws {
        let yaml = """
        mcp:
          - nome: arquivos
            comando: [npx, -y, servidor]
            env:
              TOKEN: $MEU_TOKEN
            classes:
              ler: read
              escrever: local_write
        agentes_externos:
          corpo: true
        """
        let cfg = try MiniYAML.decode(DaemonConfig.self, from: yaml)
        XCTAssertEqual(cfg.mcp?.first?.classes?["ler"], .read)
        XCTAssertEqual(cfg.mcp?.first?.classes?["escrever"], .localWrite)
        XCTAssertEqual(cfg.mcp?.first?.env?["TOKEN"], "$MEU_TOKEN")
        XCTAssertEqual(cfg.agentes_externos?.corpo, true)
        // O modelo de config continua válido.
        XCTAssertNoThrow(try MiniYAML.decode(DaemonConfig.self, from: DaemonConfig.template))
    }

    // MARK: - Agente externo como cérebro

    /// Agente falso em sh (glyph-brain/1): pede a ferramenta "hora" e depois
    /// responde com o resultado. Escreve lixo e respostas velhas no meio.
    static let fakeAgent = #"""
    while IFS= read -r line; do
      rid=$(printf '%s' "$line" | sed -n 's/^{"id":"\([^"]*\)".*/\1/p')
      printf 'lixo que não é json\n'
      case "$line" in
        *'"role":"tool_results"'*)
          out=$(printf '%s' "$line" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
          printf '{"type":"brain.reply","id":"%s","text":"feito: %s","stop":"done","usage":{"input_tokens":10,"output_tokens":3},"model":"vk-teste"}\n' "$rid" "$out" ;;
        *)
          printf '{"type":"brain.reply","id":"velho","text":"ignorar"}\n'
          printf '{"type":"brain.reply","id":"%s","text":"","tool_calls":[{"id":"c1","name":"hora","input":{}}],"stop":"tool_use","usage":{"input_tokens":5,"output_tokens":2}}\n' "$rid" ;;
      esac
    done
    """#

    func testExternalAgentBrainDrivesTheLoopThroughThePolicy() async throws {
        let path = try script("agente.sh", Self.fakeAgent)
        let brain = ExternalAgentBrain(name: "vk", command: [path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        XCTAssertEqual(brain.id, "externo:vk")
        let hora = FakeTool(name: "hora", cls: .read, output: "12h")
        let r = try await AgentLoop(brain: brain, tools: ToolRegistry([hora])).run("que horas são?", cues: SilentCues(approveAll: false))
        XCTAssertEqual(r.answer, "feito: 12h")
        XCTAssertEqual(hora.calls.value, 1)
        XCTAssertEqual(r.usage.total, 20)
        await brain.stop()
    }

    func testExternalAgentCannotSkipApproval() async throws {
        let path = try script("agente.sh", Self.fakeAgent)
        let brain = ExternalAgentBrain(name: "vk", command: [path], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        let hora = FakeTool(name: "hora", cls: .externalEffect, output: "enviado")
        let r = try await AgentLoop(brain: brain, tools: ToolRegistry([hora])).run("manda", cues: SilentCues(approveAll: false))
        XCTAssertEqual(hora.calls.value, 0, "o agente pensa; quem age é o glyphd, pela política")
        XCTAssertEqual(r.steps.first?.decision, .ask)
        await brain.stop()
    }

    func testExternalAgentFailuresAreTransportErrors() async throws {
        let quits = try script("sai.sh", "exit 0\n")
        let b1 = ExternalAgentBrain(name: "sai", command: [quits], environment: [:], timeout: 5)
        do {
            _ = try await b1.respond(system: "", turns: [.user("oi")], tools: [])
            XCTFail("devia falhar")
        } catch let e as BrainError {
            if case .transport = e {} else { XCTFail("\(e)") }
        }
        let mute = try script("mudo.sh", "cat > /dev/null\n")
        let b2 = ExternalAgentBrain(name: "mudo", command: [mute], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        let start = Date()
        do {
            _ = try await b2.respond(system: "", turns: [.user("oi")], tools: [])
            XCTFail("devia estourar o tempo")
        } catch let e as BrainError {
            XCTAssertEqual(e, .transport("agente externo não respondeu a tempo (1 s)"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        await b2.stop()
    }

    func testCommandsKeepBareNamesForThePath() {
        let argv = Runtime.expandCommand(["python3", "~/agente.py", "-y", "rel/x"])
        XCTAssertEqual(argv[0], "python3")
        XCTAssertEqual(argv[1], NSHomeDirectory() + "/agente.py")
        XCTAssertEqual(argv[2...], ["-y", "rel/x"])
    }

    func testExternalAgentReplyValidation() throws {
        XCTAssertThrowsError(try ExternalAgentBrain.decodeReply(.object(["tool_calls": .array([.object(["input": .object([:])])])])))
        XCTAssertThrowsError(try ExternalAgentBrain.decodeReply(.object(["tool_calls": .array([.object(["name": .string("x"), "input": .string("não")])])])))
        let r = try ExternalAgentBrain.decodeReply(.object(["text": .string("oi"), "stop": .string("refusal")]))
        XCTAssertEqual(r.stop, .refusal(nil))
        let req = ExternalAgentBrain.encodeRequest(id: "r1", system: "s", turns: [
            .user("a"), .assistant(text: "b", toolCalls: [ToolCall(id: "c", name: "t", input: .object([:]))], raw: .string("segredo do provedor")),
            .toolResults([ToolResult(callID: "c", name: "t", content: "saida")]),
        ], tools: [ToolSpec(name: "t", description: "d", inputSchema: .object([:]))])
        XCTAssertEqual(req["protocol"]?.stringValue, "glyph-brain/1")
        XCTAssertFalse(req.description.contains("segredo do provedor"), "o raw de outro provedor não vaza para o agente")
        XCTAssertEqual(req["turns"]?.arrayValue?.count, 3)
    }

    // MARK: - Agente externo no socket

    func makeServer(allowAgents: Bool) async throws -> (GlyphServer, String) {
        let path = dir.appendingPathComponent("glyphd.sock").path
        let server = GlyphServer(options: .init(socketPath: path, allowExternalAgents: allowAgents),
                                 agent: AgentLoop(brain: ScriptedBrain(replies: []), tools: ToolRegistry()),
                                 log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        return (server, path)
    }

    func testExternalAgentOnSocketOnlyPuppetsTheBody() async throws {
        let (server, path) = try await makeServer(allowAgents: true)
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        XCTAssertTrue(body.waitFor { $0.contains { if case .hello = $0 { return true }; return false } })
        let agent = try FakeBody(path: path)
        agent.send(.hello(Hello(role: .brain, name: "vk")))
        XCTAssertTrue(agent.waitFor { $0.contains { if case let .hello(h) = $0 { return h.role == .body }; return false } })
        agent.send(.approvalRequest(ApprovalRequest(action: "push", target: "origin", actionClass: .externalEffect, why: "confia")))
        agent.send(.bodyEmote(BodyEmote(clip: "await")))
        agent.send(.bodyEmote(BodyEmote(clip: "wave", sticker: "cartao")))
        agent.send(.bodyEmote(BodyEmote(clip: "wave", dot: .blink)))
        agent.send(.worldUpdate(WorldUpdate()))
        agent.send(.bodyEmote(BodyEmote(clip: "wave")))
        agent.send(.bubbleSay(BubbleSay(text: "oi do vk", durationSec: 30)))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "oi do vk" }; return false } })
        let msgs = body.messages
        XCTAssertFalse(msgs.contains { if case .approvalRequest = $0 { return true }; return false }, "agente externo não pede aprovação")
        let emotes = msgs.compactMap { m -> BodyEmote? in if case let .bodyEmote(e) = m { return e }; return nil }
        XCTAssertEqual(emotes, [BodyEmote(clip: "wave")], "sinais de segurança não passam")
        let bubble = msgs.compactMap { m -> BubbleSay? in if case let .bubbleSay(b) = m { return b }; return nil }.first
        XCTAssertEqual(bubble?.durationSec, 8)
        // O agente não recebe nada do corpo.
        XCTAssertEqual(agent.messages.count, 1)

        // Freio puxado: o agente fica mudo.
        body.send(.inputBrake(InputBrake(engage: true)))
        try await Task.sleep(nanoseconds: 200_000_000)
        agent.send(.bubbleSay(BubbleSay(text: "ainda aqui")))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(body.messages.contains { if case let .bubbleSay(b) = $0 { return b.text == "ainda aqui" }; return false })
        await server.stop()
    }

    func testExternalAgentsAreOffByDefault() async throws {
        let (server, path) = try await makeServer(allowAgents: false)
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        XCTAssertTrue(body.waitFor { $0.contains { if case .hello = $0 { return true }; return false } })
        let agent = try FakeBody(path: path)
        agent.send(.hello(Hello(role: .brain, name: "vk")))
        agent.send(.bubbleSay(BubbleSay(text: "posso?")))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(body.messages.contains { if case .bubbleSay = $0 { return true }; return false })
        let count = await server.sessionCount
        XCTAssertEqual(count, 1, "a conexão do agente foi fechada")
        await server.stop()
    }

    // MARK: - Mala

    func testMalaCarriesWhatTheUserWroteAndLeavesTrustBehind() throws {
        let casa = dir.appendingPathComponent("casa-a")
        let fm = FileManager.default
        for d in ["skills/_rascunhos", "skills/testes", "memoria", "packs/meu/clips", "diario"] {
            try fm.createDirectory(at: casa.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try "- id: testes\n  descricao: manter os testes verdes\n".write(to: casa.appendingPathComponent("goals.yaml"), atomically: true, encoding: .utf8)
        try "corpo:\n  equipe: \"\"\n  pareados: [abc123]\n".write(to: casa.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "rodar swift test".write(to: casa.appendingPathComponent("skills/testes/SKILL.md"), atomically: true, encoding: .utf8)
        try "rascunho".write(to: casa.appendingPathComponent("skills/_rascunhos/x.md"), atomically: true, encoding: .utf8)
        try "gosta de café".write(to: casa.appendingPathComponent("memoria/notas.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: casa.appendingPathComponent("packs/meu/pack.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: casa.appendingPathComponent("policy.yaml"), atomically: true, encoding: .utf8)
        try "{}".write(to: casa.appendingPathComponent("diario/hoje.md"), atomically: true, encoding: .utf8)

        let file = dir.appendingPathComponent("mala.json")
        let files = try Mala.export(casa: casa, to: file, origin: "teste")
        XCTAssertEqual(files, ["config.yaml", "goals.yaml", "memoria/notas.md", "packs/meu/pack.json", "skills/testes/SKILL.md"])

        let casaB = dir.appendingPathComponent("casa-b")
        try fm.createDirectory(at: casaB.appendingPathComponent("memoria"), withIntermediateDirectories: true)
        try "outra nota".write(to: casaB.appendingPathComponent("memoria/notas.md"), atomically: true, encoding: .utf8)
        let r = try Mala.importBundle(file, into: casaB)
        XCTAssertEqual(r.conflicts, ["memoria/notas.md"])
        XCTAssertEqual(try String(contentsOf: casaB.appendingPathComponent("memoria/notas.md"), encoding: .utf8), "outra nota", "nunca sobrescreve")
        XCTAssertEqual(try String(contentsOf: casaB.appendingPathComponent("memoria/notas.md.da-mala"), encoding: .utf8), "gosta de café")
        XCTAssertTrue(r.written.contains("goals.yaml"))
        let cfg = try String(contentsOf: casaB.appendingPathComponent("config.yaml"), encoding: .utf8)
        XCTAssertTrue(cfg.contains("pareados: []"), "pareamento é por máquina")
        XCTAssertFalse(fm.fileExists(atPath: casaB.appendingPathComponent("policy.yaml").path))
        XCTAssertFalse(fm.fileExists(atPath: casaB.appendingPathComponent("skills/_rascunhos").path))
        // Importar de novo não muda nada.
        let again = try Mala.importBundle(file, into: casaB)
        XCTAssertTrue(again.written.isEmpty)
    }

    func testMalaRejectsSymlinkEscapingCasa() throws {
        let fm = FileManager.default
        let source = dir.appendingPathComponent("origem-link")
        try fm.createDirectory(at: source.appendingPathComponent("memoria"), withIntermediateDirectories: true)
        try "segredo".write(to: source.appendingPathComponent("memoria/notas.md"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("mala-link.json")
        _ = try Mala.export(casa: source, to: file)

        let casa = dir.appendingPathComponent("casa-link")
        let outside = dir.appendingPathComponent("fora-link")
        try fm.createDirectory(at: casa, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: casa.appendingPathComponent("memoria"), withDestinationURL: outside)

        let report = try Mala.importBundle(file, into: casa)
        XCTAssertEqual(report.skipped, ["memoria/notas.md"])
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("notas.md").path))
    }

    func testMalaRefusesEscapesAndBadGoals() throws {
        let bundle = """
        {"formato":"glyph-mala/1","criado":"2026-09-29T12:00:00Z","origem":"x","arquivos":{
          "../fora.txt":"\(Data("x".utf8).base64EncodedString())",
          "memoria/../../fora2.txt":"\(Data("x".utf8).base64EncodedString())",
          "policy.yaml":"\(Data("x".utf8).base64EncodedString())",
          "goals.yaml":"\(Data("- id: push\\n  descricao: x\\n  classes_permitidas: [external_effect]\\n".utf8).base64EncodedString())"
        }}
        """
        let file = dir.appendingPathComponent("ruim.json")
        try bundle.write(to: file, atomically: true, encoding: .utf8)
        let casa = dir.appendingPathComponent("casa")
        let r = try Mala.importBundle(file, into: casa)
        XCTAssertTrue(r.written.isEmpty)
        XCTAssertEqual(r.skipped.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fora.txt").path))
    }
}
