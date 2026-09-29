import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

/// Um corpo falso: conecta no socket e grava tudo que o cérebro manda.
final class FakeBody: @unchecked Sendable {
    let conn: LineConnection
    private let lock = NSLock()
    private var received: [Message] = []
    var autoApprove: Bool?
    var alwaysApprove = false

    init(path: String) throws {
        conn = try UnixSocketClient.connect(path: path)
        conn.onLine = { [weak self] r in
            guard let self, case let .success(env) = r else { return }
            self.record(env.message)
            if case .approvalRequest = env.message, self.alwaysApprove {
                self.conn.send(Envelope(id: "resp", message: .approvalResponse(ApprovalResponse(
                    requestId: env.id, decision: .always(scope: "/", expires: Date().addingTimeInterval(365 * 86_400))))))
            } else if case .approvalRequest = env.message, let yes = self.autoApprove {
                self.conn.send(Envelope(id: "resp", message: .approvalResponse(
                    ApprovalResponse(requestId: env.id, decision: yes ? .approve : .deny))))
            }
        }
        conn.start()
    }

    private func record(_ m: Message) { lock.lock(); received.append(m); lock.unlock() }

    var messages: [Message] { lock.lock(); defer { lock.unlock() }; return received }

    func send(_ m: Message) { conn.send(Envelope(id: UUID().uuidString, message: m)) }

    func waitFor(_ timeout: TimeInterval = 5, _ predicate: ([Message]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if predicate(messages) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate(messages)
    }
}

final class ServerTests: XCTestCase {
    var path: String!

    override func setUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gs-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("glyphd.sock").path
    }

    func makeServer(brain: any Brain, tools: [any Tool], trustUnverified: Bool = false, approvalTimeout: Double = 5) async throws -> GlyphServer {
        let server = GlyphServer(options: .init(socketPath: path, trustUnverifiedBodies: trustUnverified, approvalTimeout: approvalTimeout),
                                 agent: AgentLoop(brain: brain, tools: ToolRegistry(tools)),
                                 log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        return server
    }

    let browser = WindowSummary(pid: 42, app: "Safari", frame: Rect(x: 300, y: 200, width: 800, height: 500))

    /// Aceite do M2: "Glyph, quanto está o dólar?" → ele vai até o navegador,
    /// a consulta real passa pela ferramenta, ele volta e responde numa bolha.
    func testDollarQuestionEndToEnd() async throws {
        let search = WebSearchTool(transport: FakeTransport(json: duckHTML))
        let brain = ScriptedBrain { _, turns, _ in
            if case let .toolResults(r)? = turns.last {
                // O cérebro lê o resultado da ferramenta de verdade.
                let price = r[0].content.contains("R$ 5,42") ? "R$ 5,42" : "?"
                return BrainReply(text: "US$ 1 = \(price) agora.")
            }
            return toolUse("web_search", ["query": .string("cotação dólar hoje")])
        }
        let server = try await makeServer(brain: brain, tools: [search])
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        let home = Vec2(100, 80)
        body.send(.worldUpdate(WorldUpdate(activeApp: "Notas", windows: [browser], glyph: home)))
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "Glyph, quanto está o dólar?")))

        XCTAssertTrue(body.waitFor { $0.contains { if case .bubbleSay = $0 { return true }; return false } })
        let msgs = body.messages
        // Pensou, foi até o navegador, trabalhou, voltou e falou — nessa ordem.
        func index(_ p: (Message) -> Bool) -> Int { msgs.firstIndex(where: p) ?? -1 }
        let think = index { if case let .bodyEmote(e) = $0 { return e.clip == "think" }; return false }
        let gotoBrowser = index { if case let .bodyGoto(g) = $0, case let .window(pid, _) = g.target { return pid == 42 }; return false }
        let work = index { if case let .bodyEmote(e) = $0 { return e.clip == "work" }; return false }
        let back = index { if case let .bodyGoto(g) = $0, case let .point(p) = g.target { return p == home }; return false }
        let say = index { if case .bubbleSay = $0 { return true }; return false }
        XCTAssertTrue(think >= 0 && think < gotoBrowser && gotoBrowser < work && work < back && back < say, "\(msgs)")
        guard case let .bubbleSay(b) = msgs[say] else { return XCTFail() }
        XCTAssertEqual(b.text, "US$ 1 = R$ 5,42 agora.")
        XCTAssertLessThanOrEqual(b.displayText.count, BubbleSay.maxLength)
        await server.stop()
    }

    func testApprovalFromUnverifiedBodyIsIgnored() async throws {
        let push = FakeTool(name: "git_push", cls: .externalEffect, output: "ok")
        let brain = ScriptedBrain(replies: [toolUse("git_push"), BrainReply(text: "não enviei.")])
        let server = try await makeServer(brain: brain, tools: [push], approvalTimeout: 0.5)
        let body = try FakeBody(path: path)
        body.autoApprove = true
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "manda pro github")))
        XCTAssertTrue(body.waitFor { $0.contains { if case .bubbleSay = $0 { return true }; return false } })
        // Corpo sem assinatura conferida nem recebe o pedido; a ação é negada.
        XCTAssertFalse(body.messages.contains { if case .approvalRequest = $0 { return true }; return false })
        XCTAssertEqual(push.calls.value, 0)
        await server.stop()
    }

    func testApprovalRoundTripInDevMode() async throws {
        let push = FakeTool(name: "git_push", cls: .externalEffect, output: "ok")
        let brain = ScriptedBrain(replies: [toolUse("git_push", text: "Testes passaram; abrir PR?"), BrainReply(text: "PR aberto.")])
        let server = try await makeServer(brain: brain, tools: [push], trustUnverified: true)
        let body = try FakeBody(path: path)
        body.autoApprove = true
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "abre o PR")))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "PR aberto." }; return false } })
        XCTAssertEqual(push.calls.value, 1)
        let req = body.messages.compactMap { m -> ApprovalRequest? in if case let .approvalRequest(r) = m { return r }; return nil }.first
        XCTAssertEqual(req?.actionClass, .externalEffect)
        XCTAssertEqual(req?.why, "Testes passaram; abrir PR?")
        await server.stop()
    }

    func testApprovalTimeoutDenies() async throws {
        let push = FakeTool(name: "git_push", cls: .externalEffect, output: "ok")
        let brain = ScriptedBrain(replies: [toolUse("git_push"), BrainReply(text: "ok, deixo.")])
        let server = try await makeServer(brain: brain, tools: [push], trustUnverified: true, approvalTimeout: 0.3)
        let body = try FakeBody(path: path) // não responde
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "manda")))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "ok, deixo." }; return false } })
        XCTAssertEqual(push.calls.value, 0, "timeout nega")
        await server.stop()
    }

    func testHelloAndEmptySummonAndBadMessages() async throws {
        let server = try await makeServer(brain: ScriptedBrain(replies: [BrainReply(text: "x")]), tools: [])
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        body.send(.bubbleSay(BubbleSay(text: "o corpo não manda falar"))) // remetente errado: ignorado
        body.send(.inputSummon(InputSummon(source: .click)))
        XCTAssertTrue(body.waitFor { m in
            m.contains { if case let .hello(h) = $0 { return h.role == .brain }; return false }
                && m.contains { if case let .bubbleSay(b) = $0 { return b.text == "oi." }; return false }
        })
        let count = await server.sessionCount
        XCTAssertEqual(count, 1)
        await server.stop()
    }

    func testBrainErrorBecomesShortBubble() async throws {
        let failing = AnthropicBrain(apiKey: "", transport: FakeTransport(json: "{}"))
        let server = try await makeServer(brain: failing, tools: [])
        let body = try FakeBody(path: path)
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "oi?")))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "sem chave de API." }; return false } })
        await server.stop()
    }
}
