import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

final class ProjectTrackerTests: XCTestCase {
    var base: URL!
    var repo: URL!
    var paths: GlyphPaths!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("glyph-retomada-\(UUID().uuidString.prefix(6))")
        repo = base.appendingPathComponent("vk")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = TaskShelfTests.sh("""
            git init -q -b main && git config user.name t && git config user.email t@t && echo 1 > a.swift && git add . \
            && git commit -qm "reconexão: backoff" && git checkout -qb fix/reconexao && echo 2 > a.swift && echo x > novo.swift
            """, in: repo)
        paths = GlyphPaths(support: base.appendingPathComponent("support"))
        try? paths.ensureCasa()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    /// Aceite: trabalhando no VK, ele guarda onde parou (só metadados); ao
    /// voltar horas depois, diz numa linha, e o marcador é editável.
    func testRemembersWhereYouStoppedAndTellsWhenYouReturn() async throws {
        let t = ProjectTracker(repos: [repo.path], paths: paths)
        let t0 = Date()
        let first = await t.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path), now: t0)
        XCTAssertNil(first, "primeira vez: nada a dizer")
        await t.testFailure(in: repo.path, at: "ReconnectTests.swift:88", now: t0)

        let m = await t.marker(Scope.normalize(repo.path))
        XCTAssertEqual(m.fact(.branch)?.text, "`fix/reconexao`")
        XCTAssertEqual(m.fact(.commit)?.text, "\"reconexão: backoff\"")
        XCTAssertEqual(m.fact(.changes)?.text, "a.swift, novo.swift")
        XCTAssertEqual(m.fact(.failing)?.text, "ReconnectTests.swift:88")
        let file = try String(contentsOf: paths.memoria.appendingPathComponent("projetos/vk.md"), encoding: .utf8)
        XCTAssertFalse(file.contains("1\n") && file.contains("2\n"), "nunca o conteúdo dos arquivos")

        // Pouco depois: silêncio.
        let soon = await t.handle(SensorEvent(kind: "shell.exit", cmd: "ls", code: 0, cwd: repo.path), now: t0.addingTimeInterval(600))
        XCTAssertNil(soon)
        // Você anota o que falta.
        _ = await t.note("vk", "falta verificar o timeout", now: t0)
        // Três horas longe: ao voltar, uma linha.
        let back = await t.handle(SensorEvent(kind: "shell.exit", cmd: "git status", code: 0, cwd: repo.appendingPathComponent("Sources").path),
                                  now: t0.addingTimeInterval(4 * 3600))
        XCTAssertEqual(back?.line, "vk: falta verificar o timeout")
    }

    func testPassingTestsClearTheFailure() async {
        let t = ProjectTracker(repos: [repo.path], paths: paths)
        await t.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: repo.path))
        await t.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 0, cwd: repo.path))
        let m = await t.marker(Scope.normalize(repo.path))
        XCTAssertNil(m.fact(.failing))
        XCTAssertNotNil(m.fact(.passing))
    }

    func testOutsideChosenFoldersNothingIsRecorded() async {
        let t = ProjectTracker(repos: [repo.path], paths: paths)
        await t.handle(SensorEvent(kind: "shell.exit", cmd: "swift test", code: 1, cwd: base.path))
        let dir = paths.memoria.appendingPathComponent("projetos").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    /// Pelo servidor: voltar ao projeto gera bolha e o alfinete na mão, que abre o marcador.
    func testServerTellsTheBodyOnReturn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sock = dir.appendingPathComponent("glyphd.sock").path
        let server = GlyphServer(options: .init(socketPath: sock), agent: AgentLoop(brain: ScriptedBrain(replies: []), tools: ToolRegistry()),
                                 log: DaemonLog(dir: nil, echo: false))
        try await server.start()
        let t = ProjectTracker(repos: [repo.path], paths: paths)
        _ = await t.note("vk", "falta o timeout", now: Date().addingTimeInterval(-5 * 3600))
        await server.attach(projects: t)
        let body = try FakeBody(path: sock)
        body.send(.hello(Hello(role: .body)))
        XCTAssertTrue(body.waitFor { $0.contains { if case .hello = $0 { return true }; return false } })
        await server.sensorEvent(SensorEvent(kind: "shell.exit", cmd: "ls", code: 0, cwd: repo.path))
        XCTAssertTrue(body.waitFor { $0.contains { if case let .taskUpdate(u) = $0 { return u.object == "alfinete" }; return false } })
        let u = body.messages.compactMap { m -> TaskUpdate? in if case let .taskUpdate(u) = m { return u }; return nil }.first
        XCTAssertEqual(u?.pending, "vk: falta o timeout")
        XCTAssertEqual(u?.open?.hasSuffix("memoria/projetos/vk.md"), true)
        await server.stop()
    }
}
