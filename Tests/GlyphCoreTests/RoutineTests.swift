import XCTest
@testable import GlyphCore

final class RoutineTests: XCTestCase {
    let demo = [
        DemoStep(command: "cd ~/clientes/acme", cwd: "/u", code: 0),
        DemoStep(command: "ls", cwd: "/u/clientes/acme", code: 0),
        DemoStep(command: "mkdir -p relatorio", cwd: "/u/clientes/acme", code: 0),
        DemoStep(command: "pandoc notas.md -o relatorio/acme.pdf", cwd: "/u/clientes/acme", code: 0),
        DemoStep(command: "pandc erro", cwd: "/u/clientes/acme", code: 127),
        DemoStep(command: "git push", cwd: "/u/clientes/acme", code: 0),
    ]

    func testDraftKeepsRealStepsWithParametersAndClasses() {
        let r = Routine.draft(name: "relatorio", demo: demo, parameters: ["cliente": "acme"])
        XCTAssertEqual(r.steps.map(\.command), ["mkdir -p relatorio", "pandoc notas.md -o relatorio/{cliente}.pdf", "git push"],
                       "sem navegação, sem o que falhou")
        XCTAssertEqual(r.steps[1].cwd, "/u/clientes/{cliente}")
        XCTAssertEqual(r.steps.last?.actionClass, .externalEffect)
        XCTAssertTrue(r.hasIrreversible)
        XCTAssertFalse(r.approved, "aprender não autoriza")
        let md = r.render()
        XCTAssertTrue(md.contains("`git push` em `/u/clientes/{cliente}` · external_effect — pede cartão a cada execução"))
        XCTAssertTrue(md.contains("Só vira rotina ativa com a sua aprovação"))
    }

    func testInstantiateFillsValuesAndRejectsShellSyntax() {
        let r = Routine.draft(name: "relatorio", demo: demo, parameters: ["cliente": "acme"])
        XCTAssertEqual(r.instantiate(["cliente": "beta"])?[1].command, "pandoc notas.md -o relatorio/beta.pdf")
        XCTAssertNil(r.instantiate([:]), "falta parâmetro")
        for bad in ["x; rm -rf ~", "$(whoami)", "a/../b", "`id`", "-rf", "a'b"] {
            XCTAssertNil(r.instantiate(["cliente": bad]), bad)
        }
    }

    func testForbiddenStepsAreMarked() {
        let r = Routine.draft(name: "x", demo: [DemoStep(command: "sudo reboot", cwd: "/", code: 0)], parameters: [:])
        XCTAssertTrue(r.steps[0].forbidden)
        XCTAssertTrue(r.render().contains("proibido: fica de fora"))
    }

    func testSuggestsRepeatedWords() {
        XCTAssertEqual(Routine.suggestParameters(demo).first, "acme")
    }
}
