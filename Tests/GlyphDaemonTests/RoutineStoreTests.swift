import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

final class RoutineStoreTests: XCTestCase {
    var base: URL!
    var store: RoutineStore!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-rotina-\(UUID().uuidString.prefix(6))")
        let paths = GlyphPaths(support: base.appendingPathComponent("support"))
        try? paths.ensureCasa()
        store = RoutineStore(paths: paths)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func teach() throws -> Routine {
        try store.start(name: "relatorio", parameters: ["cliente": "acme"])
        XCTAssertThrowsError(try store.start(name: "outra", parameters: [:]), "uma por vez")
        let dir = base.appendingPathComponent("clientes/acme").path
        store.record(SensorEvent(kind: "shell.exit", cmd: "mkdir -p out", code: 0, cwd: dir))
        store.record(SensorEvent(kind: "shell.start", cmd: "ignorado", cwd: dir))
        store.record(SensorEvent(kind: "shell.exit", cmd: "touch out/acme.txt", code: 0, cwd: dir))
        return try store.finish()
    }

    /// Aceite: você demonstra; ele mostra passos, parâmetros e permissões; só
    /// depois de aprovar ele roda, e a primeira vez com um cliente novo é ensaio.
    func testTeachApproveRehearseRun() async throws {
        let r = try teach()
        XCTAssertNil(store.current(), "a sessão fechou")
        XCTAssertEqual(r.steps.map(\.command), ["mkdir -p out", "touch out/{cliente}.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mdPath(r)))

        let never: @Sendable (RoutineStep) async throws -> ToolOutput = { _ in XCTFail("não devia rodar"); return ToolOutput("") }
        do {
            _ = try await store.run("relatorio", values: ["cliente": "beta"], decide: { _ in .actSilently }, approve: { _, _ in true }, exec: never)
            XCTFail("rascunho não roda")
        } catch let e as RoutineStore.StoreError { XCTAssertEqual(e, .notApproved("relatorio")) }

        _ = try store.approve("relatorio")
        do {
            _ = try await store.run("relatorio", values: ["cliente": "beta"], decide: { _ in .actSilently }, approve: { _, _ in true }, exec: never)
            XCTFail("sem ensaio não roda")
        } catch let e as RoutineStore.StoreError { XCTAssertEqual(e, .needsRehearsal) }

        let steps = try store.rehearse("relatorio", values: ["cliente": "beta"])
        XCTAssertEqual(steps.last?.command, "touch out/beta.txt")

        let ran = Recorder()
        let result = try await store.run("relatorio", values: ["cliente": "beta"], decide: { _ in .actSilently }, approve: { _, _ in false },
                                         exec: { s in ran.add(s.command); return ToolOutput("ok") })
        XCTAssertEqual(ran.items, ["mkdir -p out", "touch out/beta.txt"])
        XCTAssertNil(result.stoppedAt)
    }

    /// Cada passo passa pela política: o que ela manda pedir, pede; recusado, para.
    func testEachStepGoesThroughPolicy() async throws {
        _ = try teach()
        _ = try store.approve("relatorio")
        _ = try store.rehearse("relatorio", values: ["cliente": "beta"])
        let asked = Recorder(), ran = Recorder()
        let result = try await store.run("relatorio", values: ["cliente": "beta"],
                                         decide: { s in s.command.hasPrefix("touch") ? .ask("nível 1") : .actSilently },
                                         approve: { s, _ in asked.add(s.command); return false },
                                         exec: { s in ran.add(s.command); return ToolOutput("ok") })
        XCTAssertEqual(asked.items, ["touch out/beta.txt"])
        XCTAssertEqual(ran.items, ["mkdir -p out"])
        XCTAssertEqual(result.stoppedAt, "touch out/beta.txt")
    }

    func testRoutineToolRehearsesFirstAndRefusesIrreversible() async throws {
        try store.start(name: "publicar", parameters: [:])
        store.record(SensorEvent(kind: "shell.exit", cmd: "git push", code: 0, cwd: base.path))
        _ = try store.finish()
        _ = try store.approve("publicar")
        let tool = RoutineTool(store: store, shell: ShellTool(config: .init(allowedRoots: [base.path])))
        let input: JSONValue = .object(["nome": .string("publicar")])
        XCTAssertEqual(tool.classify(input), .read, "a primeira chamada só ensaia")
        let first = try await tool.run(input)
        XCTAssertTrue(first.text.hasPrefix("ensaio (nada foi executado)"))
        XCTAssertEqual(tool.classify(input), .externalEffect)
        do {
            _ = try await tool.run(input)
            XCTFail("irreversível não roda pela ferramenta")
        } catch let e as ToolError {
            guard case .forbidden = e else { return XCTFail("\(e)") }
        }
    }

    /// Pelo campo de chamada: /ensinar, os comandos do terminal, /pronto, /aprovar.
    func testSummonCommands() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gr-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sock = dir.appendingPathComponent("glyphd.sock").path
        let brain = ScriptedBrain(replies: [BrainReply(text: "não devia ser chamado")])
        let server = GlyphServer(options: .init(socketPath: sock), agent: AgentLoop(brain: brain, tools: ToolRegistry()),
                                 log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        await server.attach(routines: store)
        let body = try FakeBody(path: sock)
        func said(_ t: String) -> Bool {
            body.waitFor { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == t }; return false } }
        }
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "/ensinar backup pasta=docs")))
        XCTAssertTrue(said("anotando. /pronto quando acabar."))
        await server.sensorEvent(SensorEvent(kind: "shell.exit", cmd: "tar czf docs.tgz docs", code: 0, cwd: base.path))
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "/pronto")))
        XCTAssertTrue(said("1 passos. veja e /aprovar backup"))
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "/aprovar backup")))
        XCTAssertTrue(said("backup: rotina ativa."))
        XCTAssertEqual(store.load("backup")?.steps.first?.command, "tar czf {pasta}.tgz {pasta}")
        XCTAssertEqual(brain.callCount, 0, "comandos de ensino não vão ao cérebro")
        await server.stop()
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
