import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

/// "Por que você fez isso?": o histórico guarda gatilho, autorização, custo
/// e evidência na hora da ação.
final class WhyTests: XCTestCase {
    var repo: URL!

    override func setUp() {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-why-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    let failing = """
    Tests/VKTests/ParserTests.swift:42: error: -[ParserTests testEmpty] : XCTAssertEqual failed
    Executed 3 tests, with 1 failure (0 unexpected)
    """

    func engine(_ channel: FakeChannel, policy: PolicyStore, history: HistoryStore) -> AutonomyEngine {
        let shell = FakeTool(name: "shell", cls: .compute, output: failing, untrusted: true, toolPlace: .terminal, failing: true)
        return AutonomyEngine(tools: ToolRegistry([shell]), policy: policy, history: history,
                              context: Reflexes.Context(watched: [repo.path]), body: channel, log: DaemonLog(dir: nil, echo: false))
    }

    func testAutonomousRerunRecordsWhy() async throws {
        let url = repo.appendingPathComponent("historico.jsonl")
        let history = HistoryStore(url: url)
        let e = engine(FakeChannel(world: WorldUpdate(idleSeconds: 30)), policy: PolicyStore(policyURL: nil, trustURL: nil), history: history)
        let done = await e.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        let entry = try XCTUnwrap(done.first)
        XCTAssertEqual(entry.outcome, .done)
        XCTAssertEqual(entry.trigger?.hasPrefix("`swift test` saiu com código 1 em "), true, "\(entry.trigger ?? "")")
        XCTAssertEqual(entry.authorization?.kind, .ladder)
        XCTAssertEqual(entry.authorization?.level, 2)
        XCTAssertEqual(entry.evidence, "ParserTests.swift:42")
        XCTAssertNotNil(entry.cost?.seconds)

        // Relido do disco, dá a mesma explicação (o corpo lê assim).
        let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").last!
        let r = try JSONDecoder().decode(WhyRecord.self, from: Data(line.utf8))
        XCTAssertEqual(Explanation.lines(r), Explanation.lines(entry.why))
        XCTAssertTrue(Explanation.lines(r).contains { $0.hasPrefix("Pude sem pedir: a escada está no nível 2 para compute") })
    }

    func testRefusedCardIsRecorded() async {
        let policy = PolicyStore(policyURL: nil, trustURL: nil)
        await policy.record(TrustKey(.compute, Scope.normalize(repo.path)), approved: false) // nível 1: pede
        let done = await engine(FakeChannel(answer: false, world: WorldUpdate(idleSeconds: 30)), policy: policy,
                                history: HistoryStore(url: nil)).handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertEqual(done.first?.outcome, .denied)
        XCTAssertEqual(done.first?.authorization?.kind, .refused)
    }

    func testApprovedCardIsRecorded() async {
        let policy = PolicyStore(policyURL: nil, trustURL: nil)
        await policy.record(TrustKey(.compute, Scope.normalize(repo.path)), approved: false)
        let done = await engine(FakeChannel(answer: true, world: WorldUpdate(idleSeconds: 30)), policy: policy,
                                history: HistoryStore(url: nil)).handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertEqual(done.first?.outcome, .done)
        XCTAssertEqual(done.first?.authorization?.kind, .card)
        XCTAssertNotNil(done.first?.authorization?.at)
    }

    func testLowScoreSaysWhyItWasDropped() async {
        let done = await engine(FakeChannel(world: WorldUpdate(idleSeconds: 30, focus: .meeting)),
                                policy: PolicyStore(policyURL: nil, trustURL: nil), history: HistoryStore(url: nil))
            .handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        XCTAssertEqual(done.first?.detail?.hasPrefix("pontuação "), true, "\(done)")
    }

    /// Clique no Glyph logo depois de uma ação autônoma: a bolha explica.
    func testClickRightAfterAnActionExplainsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gw-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("glyphd.sock").path
        let history = HistoryStore(url: nil)
        await history.append(HistoryEntry(origin: .autonomous, summary: "testes falharam em vk/", actionClass: .compute,
                                          outcome: .done, trigger: "`swift test` saiu com código 1",
                                          authorization: Authorization(.ladder, level: 2, actionClass: .compute)))
        let server = GlyphServer(options: .init(socketPath: path), agent: AgentLoop(brain: ScriptedBrain(replies: []), tools: ToolRegistry()),
                                 log: DaemonLog(dir: nil, echo: false), history: history)
        try await server.start()
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        body.send(.inputSummon(InputSummon(source: .click)))
        XCTAssertTrue(body.waitFor { $0.contains { if case .bubbleSay = $0 { return true }; return false } })
        let said = body.messages.compactMap { if case let .bubbleSay(b) = $0 { return b.text }; return nil }
        XCTAssertEqual(said.first, "percebi `swift test` saiu com código 1. fiz sem pedir: tenho nível 2 para compute aqui.")
        await server.stop()
    }
}

/// Convivência (ideia 6): um build rodando vira uma dica de presença para o corpo.
final class PresenceTests: XCTestCase {
    func testBuildStartAndEndBecomePresenceHints() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("glyphd.sock").path
        let server = GlyphServer(options: .init(socketPath: path), agent: AgentLoop(brain: ScriptedBrain(replies: []), tools: ToolRegistry()),
                                 log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        let body = try FakeBody(path: path)
        body.send(.hello(Hello(role: .body)))
        XCTAssertTrue(body.waitFor { $0.contains { if case .hello = $0 { return true }; return false } })
        await server.sensorEvent(SensorEvent(kind: "shell.start", cmd: "ls", cwd: "/tmp"))
        await server.sensorEvent(SensorEvent(kind: "shell.start", cmd: "swift build", cwd: "/tmp"))
        await server.sensorEvent(SensorEvent(kind: "shell.exit", cmd: "swift build", code: 0, cwd: "/tmp", duration: 40))
        XCTAssertTrue(body.waitFor { $0.filter { if case .presenceHint = $0 { return true }; return false }.count == 2 })
        let hints = body.messages.compactMap { m -> PresenceHint.State? in if case let .presenceHint(h) = m { return h.state }; return nil }
        XCTAssertEqual(hints, [.build, .clear], "ls não é build")
        await server.stop()
    }
}
