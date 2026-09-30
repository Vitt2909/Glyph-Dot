import XCTest
@testable import GlyphCore
@testable import GlyphDaemon

final class GoalRunnerTests: XCTestCase {
    var home: URL!
    var repo: URL!

    func sh(_ cmd: String, in dir: URL) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-m4-\(UUID().uuidString.prefix(6))")
        home = base.appendingPathComponent("support")
        repo = base.appendingPathComponent("vk")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = sh("git init -q -b main && git config user.name t && git config user.email t@t && echo 1 > valor.txt && git add . && git commit -qm inicial", in: repo)
    }

    func goals() -> [Goal] {
        Goal.load(yaml: """
        - id: testes-verdes
          descricao: "Manter o valor certo"
          escopo: \(repo.path)
          sucesso: "grep -q 2 valor.txt"
          classes_permitidas: [read, compute, local_write]
          orcamento_diario: { acoes: 40, tokens: 300000, usd: 1.50 }
          horario: noite
        - id: resumo-manha
          descricao: "Diário da manhã"
          horario: "07:30"
        """).goals
    }

    /// Um cérebro que erra na primeira tentativa e acerta na segunda.
    func twoAttemptBrain() -> ScriptedBrain {
        let attempt = Counter()
        return ScriptedBrain { _, turns, _ in
            if case .toolResults? = turns.last {
                return BrainReply(text: attempt.value == 1 ? "Hipótese: talvez seja 3\nescrevi 3." : "Hipótese: o valor certo é 2\nescrevi 2.")
            }
            attempt.increment()
            let v = attempt.value == 1 ? "3" : "2"
            return BrainReply(text: "", toolCalls: [ToolCall(id: "w\(attempt.value)", name: "write_file",
                                                             input: .object(["path": .string("valor.txt"), "content": .string("\(v)\n")]))],
                              stop: .toolUse)
        }
    }

    func at(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())!
    }

    /// Aceite do M4: "testes verdes" ativo à noite → de manhã há um ramo
    /// glyph/* com a correção proposta e um diário explicando; a main está intocada.
    func testNightShiftProposesFixOnGlyphBranchAndWritesDiary() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let (_, mainBefore) = sh("git rev-parse main", in: repo)
        let channel = FakeChannel(answer: false) // de madrugada ninguém aprova nada
        let history = HistoryStore(url: paths.history)
        let board = BoardStore(url: paths.casa.appendingPathComponent("quadro.json"))
        let g = goals()
        let runner = GoalRunner(paths: paths, brain: twoAttemptBrain(), policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: history, board: board, body: channel, log: DaemonLog(dir: nil, echo: false),
                                goals: { g })
        await runner.setNightShift(true)

        let night = await runner.heartbeat(now: at(2, 0), userAway: true)
        guard case let .fixed(branch, attempts)? = night["testes-verdes"] else { return XCTFail("\(night)") }
        XCTAssertEqual(attempts, 2, "a primeira abordagem falhou; a segunda, diferente, passou")
        let b = try XCTUnwrap(branch)
        XCTAssertTrue(b.hasPrefix("glyph/"))

        // A main está intocada.
        let (_, mainAfter) = sh("git rev-parse main", in: repo)
        XCTAssertEqual(mainAfter, mainBefore)
        XCTAssertEqual(sh("git show main:valor.txt", in: repo).1, "1\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("valor.txt"), encoding: .utf8), "1\n", "cópia de trabalho do usuário intocada")
        // O ramo glyph/* tem a correção.
        XCTAssertEqual(sh("git show \(b):valor.txt", in: repo).1, "2\n")
        XCTAssertTrue(sh("git log -1 --format=%s \(b)", in: repo).1.contains("o valor certo é 2"))

        // Publicar é irreversível: pediu, ninguém respondeu, ficou para você.
        let asked = await channel.requests
        XCTAssertEqual(asked.map(\.actionClass), [.externalEffect])
        // Deu certo depois de falhar: lição em rascunho.
        let drafts = try FileManager.default.contentsOfDirectory(atPath: paths.skillDrafts.path)
        XCTAssertEqual(drafts.count, 1)

        // De manhã: o diário.
        let morning = await runner.heartbeat(now: at(7, 31), userAway: false)
        XCTAssertEqual(morning["resumo-manha"], .satisfied)
        let diaryURL = paths.diario.appendingPathComponent("\(String(ISO8601.format(at(7, 31)).prefix(10))).md")
        let diary = try String(contentsOf: diaryURL, encoding: .utf8)
        XCTAssertTrue(diary.contains("## Feito"))
        XCTAssertTrue(diary.contains("correção proposta no ramo \(b)"), diary)
        XCTAssertTrue(diary.contains("## Tentado sem sucesso"))
        XCTAssertTrue(diary.contains("talvez seja 3"), diary)
        XCTAssertTrue(diary.contains("## Precisa de você"))
        XCTAssertTrue(diary.contains("publicar: precisa de você"), diary)
        XCTAssertTrue(diary.contains("## Custos"))
        let cues = await channel.cues
        XCTAssertTrue(cues.contains { if case .diaryReady = $0 { return true }; return false })
        XCTAssertTrue(cues.contains { if case let .bodyEmote(e) = $0 { return e.sticker == "mochila" }; return false }, "sai de mochila")
    }

    func testThreeFailuresEscalate() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let never = Counter()
        let brain = ScriptedBrain { _, turns, _ in
            if case .toolResults? = turns.last { return BrainReply(text: "Hipótese: tentativa \(never.value)") }
            never.increment()
            return BrainReply(text: "", toolCalls: [ToolCall(id: "w", name: "write_file",
                                                             input: .object(["path": .string("valor.txt"), "content": .string("9\n")]))], stop: .toolUse)
        }
        let board = BoardStore(url: nil)
        let g = goals()
        let runner = GoalRunner(paths: paths, brain: brain, policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: HistoryStore(url: nil), board: board, body: FakeChannel(), log: DaemonLog(dir: nil, echo: false),
                                goals: { g })
        let out = await runner.run(g[0])
        guard case let .gaveUp(why) = out else { return XCTFail("\(out)") }
        XCTAssertTrue(why.contains("tentei 3 abordagens"))
        let task = await board.tasks.first
        XCTAssertEqual(task?.status, .needsYou)
        XCTAssertEqual(task?.attempts.count, 3)
        XCTAssertEqual(sh("git show main:valor.txt", in: repo).1, "1\n")
    }

    func testSatisfiedGoalDoesNothingAndBrakeSkips() async throws {
        _ = sh("echo 2 > valor.txt && git commit -qam dois", in: repo)
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        let brain = ScriptedBrain(replies: [BrainReply(text: "não devia ser chamado")])
        let g = goals()
        let channel = FakeChannel()
        let runner = GoalRunner(paths: paths, brain: brain, policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: HistoryStore(url: nil), board: BoardStore(url: nil), body: channel,
                                log: DaemonLog(dir: nil, echo: false), goals: { g })
        let ok = await runner.run(g[0])
        XCTAssertEqual(ok, .satisfied)
        XCTAssertEqual(brain.callCount, 0)
        await channel.pause(true)
        let braked = await runner.run(g[0])
        XCTAssertEqual(braked, .skipped("freio puxado"))
    }

    func testBudgetStopsWork() async throws {
        let paths = GlyphPaths(support: home)
        try paths.ensureCasa()
        var g = goals()[0]
        g.orcamento_diario = Goal.DailyBudget(acoes: 1)
        let goal = g
        let brain = ScriptedBrain { _, turns, _ in
            if case .toolResults? = turns.last { return BrainReply(text: "Hipótese: 7") }
            return BrainReply(text: "", toolCalls: [ToolCall(id: "w", name: "write_file",
                                                             input: .object(["path": .string("valor.txt"), "content": .string("7\n")]))], stop: .toolUse)
        }
        let runner = GoalRunner(paths: paths, brain: brain, policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: HistoryStore(url: nil), board: BoardStore(url: nil), body: FakeChannel(),
                                log: DaemonLog(dir: nil, echo: false), goals: { [goal] })
        let out = await runner.run(goal)
        XCTAssertEqual(out, .outOfBudget("ações"))
    }

    func testFileToolsStayInsideWorkspace() async {
        let w = WriteFileTool(roots: [repo.path])
        do { _ = try await w.run(.object(["path": .string("../fora.txt"), "content": .string("x")])); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("fora da pasta")) }
        do { _ = try await w.run(.object(["path": .string(".git/config"), "content": .string("x")])); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains(".git")) }
        let r = try? await ReadFileTool(roots: [repo.path]).run(.object(["path": .string("valor.txt")]))
        XCTAssertEqual(r?.untrusted, true)
    }
}

/// Objetos de tarefa e prateleira (proposta 0002, ideia 3).
final class TaskShelfTests: XCTestCase {
    static func sh(_ cmd: String, in dir: URL) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testGoalTaskIsCarriedAsAToolAndCanBeShelved() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-shelf-\(UUID().uuidString.prefix(6))")
        let repo = base.appendingPathComponent("vk")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = Self.sh("git init -q -b main && git config user.name t && git config user.email t@t && echo 1 > valor.txt && git add . && git commit -qm inicial", in: repo)
        let paths = GlyphPaths(support: base.appendingPathComponent("support"))
        try paths.ensureCasa()
        let goal = Goal.load(yaml: """
        - id: testes-verdes
          descricao: "x"
          escopo: \(repo.path)
          sucesso: "grep -q 2 valor.txt"
          classes_permitidas: [read, compute, local_write]
        """).goals[0]
        let channel = FakeChannel(answer: false)
        let board = BoardStore(url: paths.board)
        // Cérebro que nunca acerta: a tarefa fica em "precisa de você".
        let brain = ScriptedBrain { _, _, _ in BrainReply(text: "Hipótese: nada\nnão sei.") }
        let runner = GoalRunner(paths: paths, brain: brain, policy: PolicyStore(policyURL: nil, trustURL: nil),
                                history: HistoryStore(url: paths.history), board: board, body: channel,
                                log: DaemonLog(dir: nil, echo: false), goals: { [goal] })
        _ = await runner.run(goal)

        let updates = await channel.cues.compactMap { m -> TaskUpdate? in if case let .taskUpdate(u) = m { return u }; return nil }
        XCTAssertTrue(updates.allSatisfy { $0.object == "chave" }, "tarefa de código: a ferramenta na mão")
        XCTAssertEqual(updates.first?.state, .doing)
        XCTAssertEqual(updates.last?.state, .needsYou)
        XCTAssertNotNil(updates.last?.pending)

        let id = try XCTUnwrap(updates.last?.taskId)
        let parked = await runner.shelf(id, park: true)
        XCTAssertEqual(parked?.status, .parked)
        let lastCue = await channel.cues.last
        XCTAssertEqual(lastCue, .taskUpdate(parked!.update), "o corpo larga o objeto")
        let skipped = await runner.run(goal)
        XCTAssertEqual(skipped, .skipped("na prateleira"), "ninguém mexe numa tarefa estacionada")

        let resumed = await runner.shelf(id, park: false)
        XCTAssertEqual(resumed?.status, .todo)
        let again = await runner.shelf(id, park: false)
        XCTAssertNil(again, "só retoma o que está na prateleira")
        let missing = await runner.shelf("nao-existe", park: true)
        XCTAssertNil(missing)
    }
}
