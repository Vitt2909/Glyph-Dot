import XCTest
@testable import GlyphCore

final class ExplanationTests: XCTestCase {
    func testAutonomousActionExplainsTriggerAuthorizationAndEvidence() {
        let r = WhyRecord(id: "ab12cd34", origin: "autonomous", summary: "testes falharam em vk/", outcome: "done",
                          detail: "2 falha(s); primeira em Tests/ParserTests.swift:42", actionClass: .compute,
                          trigger: "`swift test` saiu com código 1 em ~/dev/vk",
                          authorization: Authorization(.ladder, level: 2, actionClass: .compute, scope: "/u/dev/vk"),
                          cost: ActionCost(seconds: 3.2), evidence: "ParserTests.swift:42")
        let lines = Explanation.lines(r)
        XCTAssertEqual(lines.first, "Percebi: `swift test` saiu com código 1 em ~/dev/vk.")
        XCTAssertTrue(lines.contains("Pude sem pedir: a escada está no nível 2 para compute em /u/dev/vk."), "\(lines)")
        XCTAssertTrue(lines.contains("Evidência: ParserTests.swift:42."))
        XCTAssertTrue(lines.contains("Custo: 3.2 s."))
        XCTAssertFalse(lines.contains { $0.contains("desfazer") }, "sem inversa, sem desfazer")
        XCTAssertEqual(Explanation.short(r),
                       "percebi `swift test` saiu com código 1 em ~/dev/vk. fiz sem pedir: tenho nível 2 para compute aqui.")
    }

    func testEachAuthorizationKindHasASentence() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Explanation.authorizationLine(Authorization(.request)), "Pude porque você pediu agora.")
        XCTAssertTrue(Explanation.authorizationLine(Authorization(.rule, actionClass: .localWrite, scope: "/x", until: until))
            .hasPrefix("Pude sem pedir: regra \"sempre\" para local_write em /x, até "))
        XCTAssertTrue(Explanation.authorizationLine(Authorization(.card, at: Date())).hasPrefix("Você aprovou no cartão às "))
        XCTAssertEqual(Explanation.authorizationLine(Authorization(.goal, actionClass: .localWrite, ref: "testes-verdes")),
                       "O objetivo testes-verdes autoriza local_write dentro do espaço da tarefa.")
        XCTAssertEqual(Explanation.authorizationLine(Authorization(.ladder, level: 0, actionClass: .compute)),
                       "A escada está no nível 0 para compute: só observo.")
        XCTAssertEqual(Explanation.authorizationLine(Authorization(.refused)), "Não foi aprovado (recusa ou tempo esgotado).")
        XCTAssertEqual(Explanation.authorizationLine(Authorization(.policy, note: "compute é proibida")),
                       "A política não deixou: compute é proibida.")
    }

    /// Linhas antigas do histórico (antes destes campos) continuam legíveis.
    func testOldHistoryLinesDecode() throws {
        let old = #"{"id":"x1","origin":"user","outcome":"done","summary":"que horas são?","ts":"2026-09-01T10:00:00Z","tool":"clock"}"#
        let r = try JSONDecoder().decode(WhyRecord.self, from: Data(old.utf8))
        XCTAssertNil(r.authorization)
        XCTAssertFalse(r.undoable)
        XCTAssertEqual(Explanation.lines(r), ["Você pediu: \"que horas são?\".", "Fiz o que você pediu (clock)."])
    }

    func testUndoableLineNamesTheCommand() throws {
        let line = #"{"id":"u9","origin":"autonomous","outcome":"done","summary":"objetivo x","inverse":{"tool":"shell","input":{},"summary":"apagar"}}"#
        let r = try JSONDecoder().decode(WhyRecord.self, from: Data(line.utf8))
        XCTAssertTrue(r.undoable)
        XCTAssertEqual(Explanation.lines(r).last, "Dá para desfazer: glyphd desfazer u9")
    }

    func testLongDetailIsFlattenedAndCut() {
        let r = WhyRecord(summary: "x", outcome: "failed", detail: String(repeating: "linha\n", count: 80))
        let d = Explanation.lines(r).first { $0.hasPrefix("Resultado:") }!
        XCTAssertFalse(d.contains("\n"))
        XCTAssertLessThanOrEqual(d.count, 175)
    }

    func testPolicyNamesTheRuleThatAllowed() {
        var p = Policy()
        let key = TrustKey(.localWrite, "/r")
        XCTAssertEqual(p.authorization(key).kind, .ladder)
        XCTAssertTrue(p.allowAlways(key, tool: nil, until: Date().addingTimeInterval(3600)))
        XCTAssertEqual(p.authorization(key).kind, .rule)
        // Irreversível nunca é "regra", mesmo que alguém edite o arquivo à mão.
        p.rules.append(PolicyRule(classe: .externalEffect, escopo: "/r", acao: nil, expira: Date().addingTimeInterval(3600)))
        XCTAssertEqual(p.authorization(TrustKey(.externalEffect, "/r")).kind, .ladder)
    }
}
