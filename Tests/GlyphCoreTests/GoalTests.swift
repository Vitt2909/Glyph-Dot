import XCTest
@testable import GlyphCore

final class GoalTests: XCTestCase {
    let planYAML = """
    - id: testes-verdes
      descricao: "Manter os testes do repositório VK passando"
      escopo: ~/dev/vk
      gatilhos: [git.commit, shell.exit_nonzero]
      sucesso: "swift test"          # código de saída 0
      classes_permitidas: [read, compute, local_write]
      orcamento_diario: { acoes: 40, tokens: 300000, usd: 1.50 }
      horario: "sempre"

    - id: resumo-manha
      descricao: "Deixar um diário do que aconteceu durante a noite"
      horario: "07:30"
      classes_permitidas: [read]
    """

    func testPlanGoalsLoad() {
        let (goals, errors) = Goal.load(yaml: planYAML)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(goals.map(\.id), ["testes-verdes", "resumo-manha"])
        XCTAssertEqual(goals[0].allowedClasses, [.read, .compute, .localWrite])
        XCTAssertEqual(goals[0].orcamento_diario?.usd, 1.5)
        XCTAssertEqual(goals[0].schedule, .always)
        XCTAssertEqual(goals[1].schedule, .daily(hour: 7, minute: 30))
    }

    func testIrreversibleClassesAndUnsafeSuccessAreRejected() {
        let (goals, errors) = Goal.load(yaml: """
        - id: ruim
          descricao: x
          classes_permitidas: [read, external_effect]
        - id: perigoso
          descricao: y
          sucesso: "rm -rf build && swift test"
        - id: Maiusculo
          descricao: z
        - id: horario-ruim
          descricao: w
          horario: "25:99"
        - id: ok
          descricao: bom
        """)
        XCTAssertEqual(goals.map(\.id), ["ok"])
        XCTAssertEqual(errors.count, 4)
        XCTAssertTrue(errors[0].contains("external_effect"))
    }

    func testSchedule() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: h, minute: m))! }
        let morning = Schedule("07:30")
        XCTAssertFalse(morning.isDue(now: at(7, 0), lastRun: nil, userAway: false, calendar: cal))
        XCTAssertTrue(morning.isDue(now: at(7, 31), lastRun: nil, userAway: false, calendar: cal))
        XCTAssertFalse(morning.isDue(now: at(9, 0), lastRun: at(7, 31), userAway: false, calendar: cal), "uma vez por dia")
        XCTAssertTrue(Schedule("noite").isDue(now: at(2, 0), lastRun: nil, userAway: false, calendar: cal))
        XCTAssertFalse(Schedule("noite").isDue(now: at(15, 0), lastRun: nil, userAway: false, calendar: cal))
        XCTAssertTrue(Schedule("noite").isDue(now: at(15, 0), lastRun: nil, userAway: true, calendar: cal), "usuário longe conta como noite")
        XCTAssertEqual(Schedule("sempre"), .always)
    }

    func testBudgetLedger() {
        var l = BudgetLedger(budget: Budget(maxActions: 3, maxTokens: 1000, maxSeconds: 60, maxUSD: 0.01))
        let opus = ModelPrice.known("anthropic:claude-opus-5-5")!
        l.charge(actions: 1, input: 200, output: 100, price: opus)
        XCTAssertEqual(l.usd, 200 / 1e6 * 4 + 100 / 1e6 * 20, accuracy: 1e-12)
        XCTAssertNil(l.exhausted(now: l.started))
        l.charge(actions: 2, price: nil)
        XCTAssertEqual(l.exhausted(now: l.started), "ações")
        XCTAssertEqual(l.actionsLeft, 0)
        var t = BudgetLedger(budget: Budget(maxSeconds: 10))
        XCTAssertEqual(t.exhausted(now: t.started + 11), "tempo")
        XCTAssertNil(t.exhausted(now: t.started + 11, checkTime: false))
        t.charge(input: 400_000, price: nil)
        XCTAssertEqual(t.exhausted(checkTime: false), "tokens")
        XCTAssertEqual(ModelPrice.known("ollama:qwen3:8b")?.cost(input: 1_000_000, output: 1_000_000), 0)
        XCTAssertNil(ModelPrice.known("openai:x"))
    }
}
