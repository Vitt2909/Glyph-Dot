import XCTest
@testable import GlyphCore
@testable import GlyphIPC
@testable import GlyphDaemon

final class RehearsalTests: XCTestCase {
    var home: URL!
    var downloads: URL!
    var store: RehearsalStore!
    let fm = FileManager.default

    override func setUp() {
        home = fm.temporaryDirectory.appendingPathComponent("glyph-ensaio-\(UUID().uuidString.prefix(6))")
        downloads = home.appendingPathComponent("Downloads")
        try? fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        store = RehearsalStore(paths: GlyphPaths(support: home.appendingPathComponent("support")))
    }

    override func tearDown() { try? fm.removeItem(at: home) }

    func put(_ name: String, _ text: String = "x", age: TimeInterval = 3600) throws {
        let url = downloads.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func listing() -> [String] {
        let e = fm.enumerator(atPath: downloads.path)
        return (e?.allObjects as? [String] ?? []).sorted()
    }

    /// Aceite: "organize Downloads" → prévia sem mexer; aprovar → aplica;
    /// desfazer → tudo volta exatamente como estava.
    func testRehearseApplyAndUndoRestoresEverything() async throws {
        try put("contrato.pdf", "c")
        try put("foto.png", "f")
        try put("Screenshot 2026-09-12 at 10.22.01.png", "s")
        try put("PDFs/relatorio.pdf", "velho")
        try put("relatorio.pdf", "novo")
        try put("rascunho.txt", age: 5)
        let before = listing()

        let plan = try store.prepare(folder: downloads.path)
        XCTAssertEqual(listing(), before, "ensaiar não mexe em nada")
        XCTAssertEqual(plan.summary, "3 arquivos seriam movidos, 1 nome mudaria e 2 casos precisam de decisão.")

        let r = try await store.apply(plan.id)
        XCTAssertEqual(r.moved, 3)
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("PDFs/contrato.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("Imagens/captura 2026-09-12 10-22-01.png").path))
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("PDFs/relatorio.pdf"), encoding: .utf8), "velho",
                       "nunca sobrescreve")
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("rascunho.txt").path), "sem decisão, fica")

        let u = try store.undo(plan.id)
        XCTAssertEqual(u.moved, 3)
        XCTAssertEqual(listing(), before, "desfazer volta tudo, e remove só as pastas que o plano criou")
        XCTAssertEqual(try store.load(plan.id).status, .undone)
        XCTAssertThrowsError(try store.undo(plan.id), "não desfaz duas vezes")
    }

    func testKeepBothAndMoveDecisions() async throws {
        try put("PDFs/relatorio.pdf", "velho")
        try put("relatorio.pdf", "novo")
        try put("recente.txt", age: 5)
        let plan = try store.prepare(folder: downloads.path)
        let conflict = try XCTUnwrap(plan.decisions.first { $0.path == "relatorio.pdf" })
        let recent = try XCTUnwrap(plan.decisions.first { $0.path == "recente.txt" })
        XCTAssertThrowsError(try store.decide(plan.id, decision: conflict.id, choice: .move), "mover não é opção numa colisão")
        _ = try store.decide(plan.id, decision: conflict.id, choice: .keepBoth)
        _ = try store.decide(plan.id, decision: recent.id, choice: .move)
        let r = try await store.apply(plan.id)
        XCTAssertEqual(r.moved, 2)
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("PDFs/relatorio (2).pdf"), encoding: .utf8), "novo")
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("PDFs/relatorio.pdf"), encoding: .utf8), "velho")
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("Documentos/recente.txt").path))
    }

    func testFileThatAppearsAfterRehearsalIsNotOverwritten() async throws {
        try put("contrato.pdf", "meu")
        let plan = try store.prepare(folder: downloads.path)
        try put("PDFs/contrato.pdf", "chegou depois")
        let r = try await store.apply(plan.id)
        XCTAssertEqual(r.moved, 0)
        XCTAssertEqual(r.skipped.count, 1)
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("PDFs/contrato.pdf"), encoding: .utf8), "chegou depois")
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("contrato.pdf"), encoding: .utf8), "meu")
    }

    func testSymlinkedDestinationIsRefused() async throws {
        try put("contrato.pdf")
        let outside = home.appendingPathComponent("fora")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: downloads.appendingPathComponent("PDFs"), withDestinationURL: outside)
        let plan = try store.prepare(folder: downloads.path)
        let r = try await store.apply(plan.id)
        XCTAssertEqual(r.moved, 0)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "nada sai da pasta")
    }

    func testTamperedPlanCannotEscapeTheFolder() async throws {
        try put("contrato.pdf")
        var plan = try store.prepare(folder: downloads.path)
        plan.steps = [PlanStep(id: "p1", kind: .move, from: "contrato.pdf", to: "../fugiu.pdf")]
        try store.save(plan)
        let r = try await store.apply(plan.id)
        XCTAssertEqual(r.moved, 0)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("fugiu.pdf").path))
    }

    /// A aprovação do plano não cobre irreversíveis: cada um pede na hora.
    func testIrreversibleStepNeedsItsOwnApproval() async throws {
        try put("a.pdf")
        var plan = try store.prepare(folder: downloads.path)
        plan.steps[0].actionClass = .destructive
        try store.save(plan)
        var asked: [String] = []
        let r = try await store.apply(plan.id) { step in asked.append(step.from); return false }
        XCTAssertEqual(asked, ["a.pdf"])
        XCTAssertEqual(r.moved, 0)
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("a.pdf").path))
    }

    func testRehearseToolOnlyInAllowedFolders() async throws {
        let tool = RehearseTool(store: store, scope: RehearsalScope(folders: [downloads.path]))
        do {
            _ = try await tool.run(.object(["pasta": .string(home.path)]))
            XCTFail("fora das pastas permitidas")
        } catch let e as ToolError {
            guard case .forbidden = e else { return XCTFail("\(e)") }
        }
        try put("a.pdf")
        let out = try await tool.run(.object(["pasta": .string(downloads.path)]))
        XCTAssertTrue(out.untrusted, "nomes de arquivos são conteúdo observado")
        XCTAssertTrue(out.text.contains("1 arquivo seria movido"))
    }

    /// Pelo campo de chamada: o cérebro ensaia, o plano vira cartão (local_write
    /// no nível 1 pede), aprovado aplica, e o histórico guarda como desfazer.
    func testSummonRehearsesThenAsksWithThePlanOnTheCard() async throws {
        try put("contrato.pdf")
        let dir = fm.temporaryDirectory.appendingPathComponent("gr-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("glyphd.sock").path
        let folder = downloads.path
        let brain = ScriptedBrain { _, turns, _ in
            if case let .toolResults(r)? = turns.last {
                if let line = r[0].content.split(separator: "\n").first, line.hasPrefix("plano ") {
                    return toolUse("aplicar_plano", ["plano": .string(String(line.dropFirst(6)))], id: "t2", text: "Posso organizar?")
                }
                return BrainReply(text: "organizado.")
            }
            return toolUse("ensaiar_organizacao", ["pasta": .string(folder)])
        }
        let tools = ToolRegistry([RehearseTool(store: store, scope: RehearsalScope(folders: [downloads.path])),
                                  ApplyPlanTool(store: store), UndoPlanTool(store: store)])
        let history = HistoryStore(url: nil)
        let server = GlyphServer(options: .init(socketPath: path, trustUnverifiedBodies: true),
                                 agent: AgentLoop(brain: brain, tools: tools), log: DaemonLog(dir: nil, echo: false), history: history)
        try await server.start()
        let body = try FakeBody(path: path)
        body.autoApprove = true
        body.send(.inputSummon(InputSummon(source: .hotkey, text: "organize Downloads")))
        XCTAssertTrue(body.waitFor(10) { $0.contains { if case let .bubbleSay(b) = $0 { return b.text == "organizado." }; return false } })
        let card = body.messages.compactMap { m -> ApprovalRequest? in if case let .approvalRequest(r) = m { return r }; return nil }.first
        XCTAssertEqual(card?.target, "organizar Downloads: 1 arquivo seria movido.")
        XCTAssertEqual(card?.actionClass, .localWrite)
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("PDFs/contrato.pdf").path))

        let applied = await history.entries.first { $0.tool == "aplicar_plano" }
        XCTAssertEqual(applied?.authorization?.kind, .card)
        let inv = try XCTUnwrap(applied?.inverse)
        XCTAssertEqual(inv.tool, "desfazer_plano")
        // O desfazer do histórico (glyphd desfazer) roda a inversa pela ferramenta.
        _ = try await tools[inv.tool]!.run(inv.input)
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("contrato.pdf").path))
        await server.stop()
    }
}
