import XCTest
@testable import GlyphCore

final class RehearsalPlanTests: XCTestCase {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func f(_ name: String, recent: Bool = false, dir: Bool = false) -> FileEntry {
        FileEntry(name: name, isDirectory: dir, modified: recent ? now.addingTimeInterval(-10) : old)
    }

    func testPlanMovesByKindTidiesNamesAndAsksAboutConflicts() {
        let entries = [
            f("contrato.pdf"), f("foto.JPG"), f("Screenshot 2026-09-12 at 10.22.01.png"), f("planilha.xlsx"),
            f("relatorio.pdf"), f("setup.dmg"), f("baixando.zip.crdownload"), f("LEIAME"), f("notas  finais .txt"),
            f("rascunho.docx", recent: true), f("Projetos", dir: true), f("PDFs", dir: true), f(".DS_Store"),
        ]
        let plan = FileOrganizer.plan(id: "t", root: "/u/Downloads", entries: entries, existing: ["PDFs/relatorio.pdf"], now: now)

        let moves = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.from, $0.to) })
        XCTAssertEqual(moves["contrato.pdf"], "PDFs/contrato.pdf")
        XCTAssertEqual(moves["foto.JPG"], "Imagens/foto.JPG", "a extensão nunca muda")
        XCTAssertEqual(moves["Screenshot 2026-09-12 at 10.22.01.png"], "Imagens/captura 2026-09-12 10-22-01.png")
        XCTAssertEqual(moves["planilha.xlsx"], "Planilhas/planilha.xlsx")
        XCTAssertEqual(moves["setup.dmg"], "Instaladores/setup.dmg")
        XCTAssertEqual(moves["notas  finais .txt"], "Documentos/notas finais.txt")
        XCTAssertNil(moves["baixando.zip.crdownload"], "download incompleto fica")
        XCTAssertTrue(plan.untouched.contains("baixando.zip.crdownload"))
        XCTAssertTrue(plan.untouched.contains("Projetos/"), "pastas do usuário ficam")
        XCTAssertFalse(plan.untouched.contains("PDFs/"), "pastas do próprio plano não contam")

        let byPath = Dictionary(uniqueKeysWithValues: plan.decisions.map { ($0.path, $0) })
        XCTAssertEqual(byPath["relatorio.pdf"]?.reason, "já existe PDFs/relatorio.pdf")
        XCTAssertEqual(byPath["relatorio.pdf"]?.options, [.skip, .keepBoth])
        XCTAssertEqual(byPath["rascunho.docx"]?.options, [.skip, .move], "mexido há pouco")
        XCTAssertEqual(byPath["LEIAME"]?.options, [.skip], "sem extensão: só pular")

        XCTAssertEqual(plan.movedCount, 6)
        XCTAssertEqual(plan.renamedCount, 2)
        XCTAssertEqual(plan.summary, "6 arquivos seriam movidos, 2 nomes mudariam e 3 casos precisam de decisão.")
        XCTAssertTrue(plan.irreversibleSteps.isEmpty)
        XCTAssertEqual(plan.classes, [.localWrite])
    }

    func testTwoFilesThatWouldCollideBecomeADecision() {
        let plan = FileOrganizer.plan(id: "t", root: "/r", entries: [f("a  b.txt"), f("a b.txt")], now: now)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.decisions.count, 1)
    }

    func testCaseInsensitiveCollision() {
        let plan = FileOrganizer.plan(id: "t", root: "/r", entries: [f("Foto.png")], existing: ["Imagens/foto.png"], now: now)
        XCTAssertTrue(plan.steps.isEmpty, "APFS ignora maiúsculas: seria sobrescrever")
    }

    func testDecisionsChangeEffectiveSteps() {
        var plan = FileOrganizer.plan(id: "t", root: "/r", entries: [f("relatorio.pdf"), f("novo.pdf", recent: true)],
                                      existing: ["PDFs/relatorio.pdf"], now: now)
        XCTAssertEqual(plan.effectiveSteps().count, 0, "sem resposta, não mexe")
        for i in plan.decisions.indices {
            plan.decisions[i].choice = plan.decisions[i].path == "relatorio.pdf" ? .keepBoth : .move
        }
        let eff = Dictionary(uniqueKeysWithValues: plan.effectiveSteps().map { ($0.from, $0.to) })
        XCTAssertEqual(eff["novo.pdf"], "PDFs/novo.pdf")
        XCTAssertEqual(eff["relatorio.pdf"], "PDFs/relatorio.pdf", "o nome livre é escolhido no disco, na hora")
    }

    func testTidyName() {
        XCTAssertEqual(FileOrganizer.tidyName("Captura de Tela 2026-01-02 às 9.05.07.png"), "captura 2026-01-02 09-05-07.png")
        XCTAssertEqual(FileOrganizer.tidyName("  espaço  demais .pdf"), "espaço demais.pdf")
        XCTAssertEqual(FileOrganizer.tidyName("ok.pdf"), "ok.pdf")
    }

    func testFreeName() {
        XCTAssertEqual(FileOrganizer.freeName("PDFs/a.pdf", taken: ["pdfs/a.pdf"]), "PDFs/a (2).pdf")
        XCTAssertEqual(FileOrganizer.freeName("PDFs/a.pdf", taken: ["pdfs/a.pdf", "pdfs/a (2).pdf"]), "PDFs/a (3).pdf")
    }

    func testSafeRelativePaths() {
        XCTAssertTrue(FileOrganizer.isSafeRelative("PDFs/a.pdf"))
        for bad in ["", "/etc/passwd", "~/x", "../x", "PDFs/../../x", ".ssh/id", "a/./b"] {
            XCTAssertFalse(FileOrganizer.isSafeRelative(bad), bad)
        }
    }

    func testNothingToDo() {
        XCTAssertEqual(FileOrganizer.plan(id: "t", root: "/r", entries: [], now: now).summary, "nada a mudar.")
    }
}
