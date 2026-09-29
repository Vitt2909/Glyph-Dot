import XCTest
@testable import GlyphCore
@testable import GlyphDaemon

final class TeamTests: XCTestCase {
    var home: URL!
    var repo: URL!

    func sh(_ cmd: String, in dir: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-m5-\(UUID().uuidString.prefix(6))")
        home = base.appendingPathComponent("support")
        repo = base.appendingPathComponent("vk")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = sh("git init -q -b main && git config user.name t && git config user.email t@t && echo 1 > valor.txt && git add . && git commit -qm inicial", in: repo)
    }

    /// Builder: na 1ª rodada faz uma gambiarra (passa no teste); depois do veto, faz direito.
    func builderBrain() -> ScriptedBrain {
        ScriptedBrain { _, turns, _ in
            if case .toolResults? = turns.last { return BrainReply(text: "Hipótese: o valor precisa ser 2\nfeito.") }
            guard case let .user(prompt)? = turns.last else { return BrainReply(text: "?") }
            let content = prompt.contains("vetou") ? "2\n" : "2 # gambiarra: hack\n"
            return BrainReply(text: "", toolCalls: [ToolCall(id: "w", name: "write_file",
                                                             input: .object(["path": .string("valor.txt"), "content": .string(content)]))],
                              stop: .toolUse)
        }
    }

    /// Auditor: veta gambiarra no diff; senão aprova.
    func auditorBrain() -> ScriptedBrain {
        ScriptedBrain { _, turns, _ in
            guard case let .user(prompt)? = turns.first else { return BrainReply(text: "?") }
            return BrainReply(text: prompt.contains("hack") ? "Achei um hack.\nVEREDITO: VETO: gambiarra no valor" : "Limpo.\nVEREDITO: APROVADO")
        }
    }

    func team(_ channel: FakeChannel, history: HistoryStore = HistoryStore(url: nil)) -> Team {
        let b = builderBrain(), a = auditorBrain()
        return Team(brainFor: { $0 == .auditor ? a : b }, policy: PolicyStore(policyURL: nil, trustURL: nil),
                    history: history, body: channel, log: DaemonLog(dir: nil, echo: false))
    }

    func testVerdictParsing() {
        XCTAssertEqual(AuditVerdict.parse("ok\nVEREDITO: APROVADO"), .approved)
        XCTAssertEqual(AuditVerdict.parse("VEREDITO: VETO: apagou um teste"), .veto("apagou um teste"))
        XCTAssertEqual(AuditVerdict.parse("parece bom"), .veto("o Auditor não deu veredito claro"), "sem veredito = veto")
        XCTAssertEqual(AuditVerdict.parse("Verdict: approved"), .approved)
    }

    func testVetoReturnsToBuilderThenApproves() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let ws = try await WorkspaceManager.prepare(scope: repo.path, taskID: "t1", casa: paths)
        let channel = FakeChannel()
        let history = HistoryStore(url: nil)
        let out = await team(channel, history: history).buildAndAudit(task: "deixe valor.txt = 2", workspace: ws,
                                                                      verify: "grep -q 2 valor.txt", label: "teste")
        XCTAssertTrue(out.approved)
        XCTAssertEqual(out.vetoes, ["gambiarra no valor"], "o teste passava, mas o Auditor vetou pelo diff")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: ws.path).appendingPathComponent("valor.txt"), encoding: .utf8), "2\n")
        let h = await history.entries
        XCTAssertTrue(h.contains { $0.summary.contains("veto do Auditor") && $0.detail == "gambiarra no valor" })
        let cues = await channel.cues
        let spawned = cues.compactMap { m -> SpecialistRole? in if case let .agentSpawn(a) = m { return a.role }; return nil }
        XCTAssertEqual(spawned, [.builder, .auditor, .builder, .auditor])
        let despawns = cues.filter { if case .agentDespawn = $0 { return true }; return false }.count
        XCTAssertEqual(despawns, 4, "todos voltam para o Dot")
        let lines = cues.compactMap { m -> String? in if case let .bubbleSay(b) = m { return b.text }; return nil }
        XCTAssertEqual(lines, ["terminou?", "sim.", "não.", "terminou?", "sim.", "aprovado."])
        XCTAssertTrue(cues.contains { if case let .bodyEmote(e) = $0 { return e.clip == "whistle" }; return false })
    }

    func testFailingTestsAreVetoedWithoutAsking() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let ws = try await WorkspaceManager.prepare(scope: repo.path, taskID: "t2", casa: paths)
        let lazy = ScriptedBrain(replies: [BrainReply(text: "Hipótese: nada a fazer")])
        let auditor = ScriptedBrain(replies: [BrainReply(text: "VEREDITO: APROVADO")])
        let t = Team(brainFor: { $0 == .auditor ? auditor : lazy }, policy: PolicyStore(policyURL: nil, trustURL: nil),
                     history: HistoryStore(url: nil), body: FakeChannel(), log: DaemonLog(dir: nil, echo: false))
        let out = await t.buildAndAudit(task: "x", workspace: ws, verify: "grep -q 2 valor.txt", label: "x")
        XCTAssertFalse(out.approved)
        XCTAssertEqual(out.vetoes.count, Team.maxAuditRounds, "2 rodadas e escala")
        XCTAssertEqual(auditor.callCount, 0, "teste falhando nem chega ao julgamento")
    }

    func testAtMostThreeSpecialists() async throws {
        let t = team(FakeChannel())
        let a = await t.spawn(.builder), b = await t.spawn(.researcher), c = await t.spawn(.auditor)
        let fourth = Task { await t.spawn(.designer) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await t.activeCount
        XCTAssertEqual(count, 3, "o quarto espera")
        await t.despawn(a)
        let d = await fourth.value
        XCTAssertTrue(d.hasPrefix("designer"))
        let after = await t.activeCount
        XCTAssertEqual(after, 3)
        await t.despawn(b); await t.despawn(c); await t.despawn(d)
    }

    func testSpecialistGateKeepsRoles() async {
        let gate = SpecialistGate(allowed: SpecialistProfile.of(.auditor).allowed,
                                  fallback: PolicyGate(store: PolicyStore(policyURL: nil, trustURL: nil)))
        let write = await gate.decide(tool: "write_file", actionClass: .localWrite, scope: "*", trusted: true, userInitiated: false)
        XCTAssertEqual(write, .deny("fora do papel deste especialista"), "Auditor não escreve código")
        let test = await gate.decide(tool: "shell", actionClass: .compute, scope: "*", trusted: true, userInitiated: false)
        XCTAssertEqual(test, .allow)
    }

    /// Aceite do M5: tarefa de código passa pelo Auditor; um veto devolve ao
    /// Builder e aparece no diário.
    func testGoalWithTeamVetoAppearsInDiary() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let history = HistoryStore(url: paths.history)
        let channel = FakeChannel()
        let goal = Goal.load(yaml: """
        - id: valor-certo
          descricao: "valor.txt precisa ser 2"
          escopo: \(repo.path)
          sucesso: "grep -q 2 valor.txt"
          classes_permitidas: [read, compute, local_write]
          horario: noite
        """).goals[0]
        let runner = GoalRunner(paths: paths, brain: builderBrain(), policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: history, board: BoardStore(url: nil), body: channel,
                                log: DaemonLog(dir: nil, echo: false), goals: { [goal] })
        await runner.setTeam(team(channel, history: history))
        let out = await runner.run(goal)
        guard case let .fixed(branch, attempts) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(attempts, 1, "uma abordagem, com um veto no meio")
        XCTAssertEqual(sh("git show \(branch!):valor.txt", in: repo), "2\n", "o que entrou no ramo é a versão aprovada")
        let diary = try String(contentsOf: await runner.writeDiary(), encoding: .utf8)
        XCTAssertTrue(diary.contains("veto do Auditor"), diary)
        XCTAssertTrue(diary.contains("gambiarra no valor"), diary)
    }
}
