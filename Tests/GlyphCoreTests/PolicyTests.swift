import XCTest
@testable import GlyphCore

final class TrustLadderTests: XCTestCase {
    let vk = "~/dev/vk"
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testInitialLevelsFromThePlan() {
        let l = TrustLadder()
        XCTAssertEqual(l.level(TrustKey(.read, vk)), .actSilently)
        XCTAssertEqual(l.level(TrustKey(.compute, vk)), .actAndTell)
        XCTAssertEqual(l.level(TrustKey(.localWrite, vk)), .suggest)
        XCTAssertEqual(l.level(TrustKey(.networkRead, vk)), .actAndTell)
        XCTAssertEqual(l.level(TrustKey(.externalEffect, vk)), .suggest)
        XCTAssertEqual(l.level(TrustKey(.destructive, vk)), .observe)
        XCTAssertNil(l.level(TrustKey(.financial, vk)), "proibido")
    }

    func testFiveApprovalsPromote() {
        var l = TrustLadder()
        let k = TrustKey(.localWrite, vk)
        for i in 0..<4 { XCTAssertFalse(l.recordApproval(k, at: t0 + Double(i) * day)) }
        XCTAssertTrue(l.recordApproval(k, at: t0 + 4 * day))
        XCTAssertEqual(l.level(k), .actAndTell)
        XCTAssertEqual(l.level(TrustKey(.localWrite, "~/dev/outro")), .suggest, "escopo separado")
    }

    func testStreakOutsideWindowDoesNotPromote() {
        var l = TrustLadder()
        let k = TrustKey(.localWrite, vk)
        for i in 0..<4 { l.recordApproval(k, at: t0 + Double(i) * day) }
        XCTAssertFalse(l.recordApproval(k, at: t0 + 15 * day), "a quinta veio fora dos 14 dias")
        XCTAssertEqual(l.level(k), .suggest)
    }

    func testRefusalDemotesAndResetsStreak() {
        var l = TrustLadder()
        let k = TrustKey(.compute, vk)
        for i in 0..<4 { l.recordApproval(k, at: t0 + Double(i)) }
        XCTAssertTrue(l.recordRefusal(k))
        XCTAssertEqual(l.level(k), .suggest)
        for i in 0..<4 { l.recordApproval(k, at: t0 + 10 + Double(i)) }
        XCTAssertEqual(l.level(k), .suggest, "a sequência recomeçou")
        l.recordUndo(k)
        l.recordUndo(k)
        XCTAssertEqual(l.level(k), .observe, "não passa de zero")
    }

    func testCeilingAndIrreversibleNeverClimb() {
        var l = TrustLadder()
        let c = TrustKey(.compute, vk)
        for i in 0..<20 { l.recordApproval(c, at: t0 + Double(i)) }
        XCTAssertEqual(l.level(c), .actSilently, "teto 3")
        let push = TrustKey(.externalEffect, vk)
        for i in 0..<50 { XCTAssertFalse(l.recordApproval(push, at: t0 + Double(i))) }
        XCTAssertEqual(l.level(push), .suggest, "irreversível não sobe")
        let rm = TrustKey(.destructive, vk)
        for i in 0..<50 { l.recordApproval(rm, at: t0 + Double(i)) }
        XCTAssertEqual(l.level(rm), .observe)
    }

    func testCodableRoundTrip() throws {
        var l = TrustLadder()
        l.recordApproval(TrustKey(.compute, vk), at: t0)
        let back = try JSONDecoder().decode(TrustLadder.self, from: try JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}

final class PolicyTests: XCTestCase {
    let vk = "~/dev/vk"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A trava de irreversíveis: nada faz uma ação irreversível rodar sem pedir.
    func testIrreversibleLockHoldsAgainstEverything() {
        var p = Policy()
        // Nem regra "sempre", nem escada, nem pedido do usuário, nem conteúdo confiável.
        XCTAssertFalse(p.allowAlways(TrustKey(.externalEffect, vk), tool: "shell", until: now + 1e6))
        XCTAssertFalse(p.allowAlways(TrustKey(.destructive, vk), tool: nil, until: now + 1e6))
        for _ in 0..<50 { p.ladder.recordApproval(TrustKey(.externalEffect, vk), at: now) }
        for userInitiated in [true, false] {
            for trusted in [true, false] {
                XCTAssertEqual(p.decide(TrustKey(.externalEffect, vk), trusted: trusted, userInitiated: userInitiated, now: now),
                               .ask("irreversível: sempre pede"))
                XCTAssertEqual(p.decide(TrustKey(.destructive, vk), trusted: trusted, userInitiated: userInitiated, now: now),
                               .askTwice("irreversível: dupla confirmação"))
                XCTAssertEqual(p.decide(TrustKey(.financial, vk), trusted: trusted, userInitiated: userInitiated, now: now),
                               .deny("financial é proibida"))
            }
        }
    }

    func testLevelsMapToDecisions() {
        let p = Policy()
        XCTAssertEqual(p.decide(TrustKey(.read, vk), now: now), .actSilently)
        XCTAssertEqual(p.decide(TrustKey(.compute, vk), now: now), .actAndTell)
        XCTAssertEqual(p.decide(TrustKey(.localWrite, vk), now: now), .ask("nível 1: sugere"))
    }

    func testObservedContentNeverRaisesPermission() {
        var p = Policy()
        _ = p.allowAlways(TrustKey(.localWrite, vk), tool: nil, until: now + 1e6)
        XCTAssertEqual(p.decide(TrustKey(.compute, vk), trusted: false, now: now), .ask("veio de conteúdo observado"))
        XCTAssertEqual(p.decide(TrustKey(.localWrite, vk), trusted: false, now: now), .ask("veio de conteúdo observado"))
        XCTAssertEqual(p.decide(TrustKey(.read, vk), trusted: false, now: now), .actSilently, "ler continua ok")
    }

    func testAlwaysRuleHasScopeAndExpiry() {
        var p = Policy()
        XCTAssertTrue(p.allowAlways(TrustKey(.localWrite, vk), tool: "shell", until: now + 3600))
        XCTAssertEqual(p.decide(TrustKey(.localWrite, vk + "/Sources"), tool: "shell", now: now), .actAndTell, "subpasta coberta")
        XCTAssertEqual(p.decide(TrustKey(.localWrite, "~/dev/vk2"), tool: "shell", now: now), .ask("nível 1: sugere"), "prefixo de texto não basta")
        XCTAssertEqual(p.decide(TrustKey(.localWrite, vk), tool: "outra", now: now), .ask("nível 1: sugere"), "só a ferramenta da regra")
        XCTAssertEqual(p.decide(TrustKey(.localWrite, vk), tool: "shell", now: now + 7200), .ask("nível 1: sugere"), "expirou")
        p.dropExpired(now: now + 7200)
        XCTAssertTrue(p.rules.isEmpty)
    }

    func testLevelZeroObservesUnlessUserAsked() {
        var p = Policy()
        let k = TrustKey(.compute, vk)
        p.ladder.recordRefusal(k)
        p.ladder.recordRefusal(k)
        XCTAssertEqual(p.decide(k, now: now), .observe("nível 0: só observa"))
        XCTAssertEqual(p.decide(k, userInitiated: true, now: now), .ask("nível 0: só com aprovação"))
    }
}

final class ScoringTests: XCTestCase {
    func intent(r: Double = 1, c: Double = 1, u: Double = 1, i: Double = 0.5, cls: ActionClass = .compute) -> Intent {
        Intent(source: "t", summary: "s", relevance: r, confidence: c, urgency: u, interruptCost: i, actionClass: cls, scope: "~")
    }

    func testFormula() {
        XCTAssertEqual(IntentScorer.score(intent(r: 0.8, c: 0.9, u: 0.5, i: 0.5), focus: 0.4), 0.8 * 0.9 * 0.5 * (1 - 0.2), accuracy: 1e-12)
    }

    func testThresholds() {
        XCTAssertEqual(IntentScorer.verdict(0.29), .discard)
        XCTAssertEqual(IntentScorer.verdict(0.3), .note)
        XCTAssertEqual(IntentScorer.verdict(0.59), .note)
        XCTAssertEqual(IntentScorer.verdict(0.6), .act)
    }

    func testFocusSuppressesInterruptions() {
        let mild = intent(r: 0.9, c: 0.9, u: 0.9, i: 0.5)
        XCTAssertEqual(IntentScorer.verdict(IntentScorer.score(mild, focus: FocusEstimator.focus(.normal, typingRecently: false))), .act)
        XCTAssertEqual(IntentScorer.verdict(IntentScorer.score(mild, focus: FocusEstimator.focus(.typing, typingRecently: true))), .note,
                       "digitando: só anota")
        let loud = intent(r: 0.9, c: 0.9, u: 0.9, i: 1)
        XCTAssertEqual(IntentScorer.verdict(IntentScorer.score(loud, focus: FocusEstimator.focus(.meeting, typingRecently: false))), .discard,
                       "em reunião ele não interrompe")
    }

    func testCalibrationLowersOverconfidence() {
        var cal = ConfidenceCalibrator()
        for k in 0..<10 { cal.record(.localWrite, predicted: 0.9, success: k < 6) }
        XCTAssertEqual(cal.calibrated(.localWrite, 0.9), 0.9 * (0.6 / 0.9), accuracy: 1e-9)
        XCTAssertEqual(cal.calibrated(.compute, 0.9), 0.9, "sem dados, confia no declarado")
        for _ in 0..<10 { cal.record(.read, predicted: 0.5, success: true) }
        XCTAssertEqual(cal.calibrated(.read, 0.5), 0.5, "nunca aumenta além do declarado")
    }
}

final class FailureParserTests: XCTestCase {
    func testXCTest() {
        let out = """
        Test Case '-[VKTests.ParserTests testEmpty]' started.
        /Users/v/dev/vk/Tests/VKTests/ParserTests.swift:42: error: -[VKTests.ParserTests testEmpty] : XCTAssertEqual failed
        /Users/v/dev/vk/Tests/VKTests/ParserTests.swift:57: error: -[VKTests.ParserTests testNil] : XCTAssertNil failed
        Executed 12 tests, with 2 failures (0 unexpected) in 0.1 seconds
        """
        let f = FailureParser.first(in: out)!
        XCTAssertEqual(f.file, "/Users/v/dev/vk/Tests/VKTests/ParserTests.swift")
        XCTAssertEqual(f.line, 42)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f.short, "ParserTests.swift:42")
    }

    func testPytestJestGoRust() {
        XCTAssertEqual(FailureParser.first(in: "FAILED tests/test_api.py::test_login - assert 1 == 2\n1 failed, 3 passed")?.file, "tests/test_api.py")
        XCTAssertEqual(FailureParser.first(in: "  ● sum › adds\n    at Object.<anonymous> (src/sum.test.ts:7:19)")?.short, "sum.test.ts:7")
        XCTAssertEqual(FailureParser.first(in: "--- FAIL: TestX (0.00s)\n    x_test.go:12: got 1")?.short, "x_test.go:12")
        XCTAssertEqual(FailureParser.first(in: "thread 'tests::it' panicked at src/lib.rs:10:5:\nassertion failed")?.short, "lib.rs:10")
        XCTAssertNil(FailureParser.first(in: "tudo certo"))
    }

    func testLooksLikeTest() {
        for c in ["swift test", "npm test", "npm run test", "pytest -q", "go test ./...", "cargo test", "make check", "yarn jest"] {
            XCTAssertTrue(FailureParser.looksLikeTestCommand(c), c)
        }
        for c in ["ls", "git status", "swift build", "echo testing123"] {
            XCTAssertFalse(FailureParser.looksLikeTestCommand(c), c)
        }
    }
}
