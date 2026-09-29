import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

/// Corpo falso do ponto de vista da autonomia.
actor FakeChannel: BodyChannel {
    var cues: [Message] = []
    var requests: [ApprovalRequest] = []
    var answer: Bool
    var worldState: WorldUpdate?
    var pausedState = false

    init(answer: Bool = false, world: WorldUpdate? = nil) {
        self.answer = answer
        self.worldState = world
    }

    func cue(_ message: Message) async { cues.append(message) }
    func approve(_ request: ApprovalRequest, key: TrustKey?) async -> Bool {
        requests.append(request)
        return answer
    }
    func world() async -> WorldUpdate? { worldState }
    func isPaused() async -> Bool { pausedState }
    func pause(_ p: Bool) { pausedState = p }
}

final class AutonomyTests: XCTestCase {
    var repo: URL!

    override func setUp() {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-repo-\(UUID().uuidString.prefix(6))")
        // Um "repositório": só precisa do .git para a raiz ser achada.
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    let terminal = WindowSummary(pid: 7, app: "Terminal", frame: Rect(x: 0, y: 100, width: 700, height: 400))

    let xctestOutput = """
    Tests/VKTests/ParserTests.swift:42: error: -[ParserTests testEmpty] : XCTAssertEqual failed
    Tests/VKTests/ParserTests.swift:57: error: -[ParserTests testNil] : XCTAssertNil failed
    Executed 12 tests, with 2 failures (0 unexpected)
    """

    /// O `shell` aqui é falso (devolve a saída do XCTest): o que se testa é a
    /// autonomia, não o shell (que tem testes próprios).
    func engine(_ channel: FakeChannel, watched: [String]? = nil, policy: PolicyStore = PolicyStore(policyURL: nil, trustURL: nil),
                shell: FakeTool? = nil) -> AutonomyEngine {
        let fake = shell ?? FakeTool(name: "shell", cls: .compute, output: xctestOutput, untrusted: true, toolPlace: .terminal, failing: true)
        let tools = ToolRegistry([fake])
        return AutonomyEngine(tools: tools, policy: policy, history: HistoryStore(url: nil),
                              context: Reflexes.Context(watched: watched ?? [repo.path]), body: channel,
                              log: DaemonLog(dir: nil, echo: false))
    }

    func failingEvent() -> SensorEvent {
        SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path, duration: 3)
    }

    /// Aceite do M3: um teste falha no terminal → ele percebe, se aproxima,
    /// roda os testes sozinho (compute, nível 2) e aponta o arquivo.
    func testFailingTestsAreRerunAndFilePointed() async throws {
        let channel = FakeChannel(world: WorldUpdate(idleSeconds: 30, windows: [terminal]))
        let e = engine(channel)
        let done = await e.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path, duration: 3))
        XCTAssertEqual(done.first?.outcome, .done, "\(done)")
        XCTAssertEqual(done.first?.detail, "2 falha(s); primeira em Tests/VKTests/ParserTests.swift:42")
        let cues = await channel.cues
        XCTAssertTrue(cues.contains { if case let .bodyGoto(g) = $0, case let .window(pid, _) = g.target { return pid == 7 }; return false },
                      "vai até o terminal")
        XCTAssertTrue(cues.contains { if case let .bodyEmote(m) = $0 { return m.clip == "point" && m.sticker == "alfinete" }; return false },
                      "aponta segurando o alfinete")
        XCTAssertTrue(cues.contains { if case let .bubbleSay(b) = $0 { return b.text == "2 falhas: ParserTests.swift:42" }; return false },
                      "\(cues)")
        let asked = await channel.requests
        XCTAssertTrue(asked.isEmpty, "compute no nível 2 não pede")
    }

    func testUnwatchedRepoOnlyPoints() async {
        let channel = FakeChannel(world: WorldUpdate(idleSeconds: 30, windows: [terminal]))
        let done = await engine(channel, watched: []).handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertEqual(done.first?.outcome, .noted, "sem repo marcado: só aponta")
        let cues = await channel.cues
        XCTAssertFalse(cues.contains { if case .bubbleSay = $0 { return true }; return false }, "silêncio por padrão")
    }

    func testMeetingSuppresses() async {
        let channel = FakeChannel(world: WorldUpdate(idleSeconds: 30, focus: .meeting))
        let done = await engine(channel).handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertNotEqual(done.first?.outcome, .done, "em reunião ele não age")
    }

    func testDemotedComputeAsksAndRefusalDemotesFurther() async {
        let policy = PolicyStore(policyURL: nil, trustURL: nil)
        let key = TrustKey(.compute, Scope.normalize(repo.path))
        await policy.record(key, approved: false) // nível 2 → 1
        let channel = FakeChannel(answer: false, world: WorldUpdate(idleSeconds: 30))
        let done = await engine(channel, policy: policy).handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertEqual(done.first?.outcome, .denied)
        let asked = await channel.requests
        XCTAssertEqual(asked.count, 1, "nível 1 gera cartão")
        let level = await policy.policy.ladder.level(key)
        XCTAssertEqual(level, .observe, "recusa desce mais um nível")
    }

    func testIgnoredEvents() async {
        let channel = FakeChannel()
        let e = engine(channel)
        let ok = await e.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 0, cwd: repo.path))
        XCTAssertTrue(ok.isEmpty, "passou: nada a fazer")
        let ctrlC = await e.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 130, cwd: repo.path))
        XCTAssertTrue(ctrlC.isEmpty, "Ctrl-C não é falha")
        let notTest = await e.handle(SensorEvent(kind: "shell.exit", cmd: "ls /nada", code: 1, cwd: repo.path))
        XCTAssertTrue(notTest.isEmpty)
        let script = await e.handle(SensorEvent(kind: "shell.exit", cmd: "./test", code: 1, cwd: repo.path))
        XCTAssertTrue(script.isEmpty, "script local desconhecido não é repetido sozinho")
        let pushTest = await e.handle(SensorEvent(kind: "shell.exit", cmd: "swift test && git push origin main", code: 1, cwd: repo.path))
        XCTAssertTrue(pushTest.isEmpty, "comando com efeito nunca é repetido sozinho")
        await channel.pause(true)
        let paused = await e.handle(failingEvent())
        XCTAssertTrue(paused.isEmpty, "freio puxado: nada")
    }

    func testCooldownAvoidsRepeating() async {
        let channel = FakeChannel(world: WorldUpdate(idleSeconds: 30))
        let e = engine(channel)
        let ev = SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path)
        _ = await e.handle(ev)
        let second = await e.handle(ev)
        XCTAssertEqual(second.first?.detail, "repetida")
    }
}

final class PolicyStoreTests: XCTestCase {
    func testRulesYAMLRoundTripAndPersistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-pol-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pURL = dir.appendingPathComponent("policy.yaml"), tURL = dir.appendingPathComponent("confianca.json")
        let store = PolicyStore(policyURL: pURL, trustURL: tURL)
        let until = Date().addingTimeInterval(3600)
        let okRule = await store.allowAlways(TrustKey(.localWrite, "~/dev/vk"), tool: "shell", until: until)
        let noRule = await store.allowAlways(TrustKey(.externalEffect, "~/dev/vk"), tool: "shell", until: until)
        XCTAssertTrue(okRule)
        XCTAssertFalse(noRule, "irreversível não vira regra")
        await store.record(TrustKey(.compute, "~/dev/vk"), approved: false)
        let text = try String(contentsOf: pURL, encoding: .utf8)
        XCTAssertTrue(text.contains("classe: local_write"))
        // Recarrega do disco.
        let again = PolicyStore(policyURL: pURL, trustURL: tURL)
        let p = await again.policy
        XCTAssertEqual(p.rules.count, 1)
        XCTAssertEqual(p.rules[0].escopo, "~/dev/vk")
        XCTAssertEqual(p.ladder.level(TrustKey(.compute, "~/dev/vk")), .suggest)
    }

    func testEmptyRulesFileIsValidYAML() throws {
        XCTAssertEqual(try MiniYAML.parse(PolicyStore.renderRules([]))["regras"], .array([]))
    }
}

final class SensorAndBrakeTests: XCTestCase {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("gsb-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSensorSocketDeliversEvents() throws {
        let path = tempDir().appendingPathComponent("sensors.sock").path
        let server = SensorServer(path: path)
        let got = expectation(description: "evento")
        let box = Box<SensorEvent?>(nil)
        server.onEvent = { e in box.value = e; got.fulfill() }
        try server.start()
        defer { server.stop() }
        let client = try UnixSocketClient.connect(path: path)
        client.start()
        client.sendRaw(Data(#"{"kind":"shell.exit","cmd":"swift test","code":1,"cwd":"/tmp","duration":2.5}"#.utf8 + [0x0A]))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(box.value?.cmd, "swift test")
        XCTAssertEqual(box.value?.code, 1)
    }

    func testGitWatcherSeesCommits() async throws {
        let repo = tempDir()
        func git(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        git("init", "-q")
        git("commit", "-q", "--allow-empty", "-m", "a")
        let events = Box<[SensorEvent]>([])
        let w = GitWatcher(repos: [repo.path]) { e in events.value.append(e) }
        await w.poll()
        XCTAssertTrue(events.value.isEmpty, "primeira leitura só memoriza")
        git("commit", "-q", "--allow-empty", "-m", "b")
        await w.poll()
        XCTAssertEqual(events.value.map(\.kind), ["git.commit"])
        XCTAssertEqual(GitWatcher.root(of: repo.appendingPathComponent("sub/pasta").path), repo.path)
    }

    /// O freio cancela o que estiver rodando, nega pendências e manda todos para casa.
    func testBrakeCancelsAndSendsEveryoneHome() async throws {
        let path = tempDir().appendingPathComponent("glyphd.sock").path
        let slow = SlowBrain()
        let server = GlyphServer(options: .init(socketPath: path, trustUnverifiedBodies: true),
                                 agent: AgentLoop(brain: slow, tools: ToolRegistry()), log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        let body = try FakeBody(path: path)
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "pensa bastante")))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bodyEmote(e) = $0 { return e.clip == "think" }; return false } })
        body.send(.inputBrake(InputBrake(engage: true)))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bodyGoto(g) = $0 { return g.target == .home }; return false } })
        let paused = await server.paused
        XCTAssertTrue(paused)
        // Nada de resposta do chamado cancelado.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(body.messages.contains { if case let .bubbleSay(b) = $0 { return b.text == "terminei" }; return false })
        // Chamar de novo solta o freio.
        body.send(.inputSummon(InputSummon(source: .click)))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "voltei." }; return false } })
        await server.stop()
    }

    func testAlwaysFromCardCreatesScopedRule() async throws {
        let path = tempDir().appendingPathComponent("glyphd.sock").path
        let write = FakeTool(name: "edit", cls: .localWrite, output: "ok")
        let brain = ScriptedBrain(replies: [toolUse("edit"), BrainReply(text: "feito.")])
        let policy = PolicyStore(policyURL: nil, trustURL: nil)
        let server = GlyphServer(options: .init(socketPath: path, trustUnverifiedBodies: true),
                                 agent: AgentLoop(brain: brain, tools: ToolRegistry([write])), log: DaemonLog(dir: nil, echo: false),
                                 policy: policy)
        try await server.start()
        let body = try FakeBody(path: path)
        body.alwaysApprove = true
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "edita")))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "feito." }; return false } })
        let rules = await policy.policy.rules
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.classe, .localWrite)
        XCTAssertEqual(rules.first?.escopo, "*", "escopo do daemon, não o texto que o corpo mandou")
        XCTAssertLessThanOrEqual(rules.first!.expira.timeIntervalSinceNow, 90 * 86_400 + 5)
        await server.stop()
    }
}

/// Cérebro lento: dorme até ser cancelado.
struct SlowBrain: Brain {
    var id: String { "lento" }
    func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return BrainReply(text: "terminei")
    }
}
