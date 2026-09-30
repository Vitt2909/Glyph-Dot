import XCTest
@testable import GlyphCore

final class FunCommandTests: XCTestCase {
    func testSlashCommandsAndNaturalPhrases() {
        XCTAssertEqual(FunCommand.parse("/diversao iniciar"), .start)
        XCTAssertEqual(FunCommand.parse("/diversão"), .start)
        XCTAssertEqual(FunCommand.parse("Vamos brincar por cinco minutos!"), .start)
        XCTAssertEqual(FunCommand.parse("/diversao parar"), .stop)
        XCTAssertEqual(FunCommand.parse("chega de brincar."), .stop)
        XCTAssertEqual(FunCommand.parse("/surpresa"), .surprise)
        XCTAssertEqual(FunCommand.parse("Me surpreenda"), .surprise)
        XCTAssertEqual(FunCommand.parse("  Dança   pra mim!! "), .dance)
        XCTAssertEqual(FunCommand.parse("/DANÇA"), .dance)
        XCTAssertEqual(FunCommand.parse("modo robô"), .robot)
        XCTAssertEqual(FunCommand.parse("/truque"), .trick)
        XCTAssertEqual(FunCommand.parse("/estátua"), .statue)
        XCTAssertEqual(FunCommand.parse("/janela-palco"), .stage)
    }

    func testCombiningAccentsAreIgnored() {
        XCTAssertEqual(FunCommand.parse("/esta\u{301}tua"), .statue)
    }

    func testAnythingElseGoesToTheBrain() {
        XCTAssertNil(FunCommand.parse("roda os testes do vk"))
        XCTAssertNil(FunCommand.parse("dança do quê?"))
        XCTAssertNil(FunCommand.parse("/danca agora e depois abre o terminal"))
        XCTAssertNil(FunCommand.parse(""))
    }
}

final class FunCatalogTests: XCTestCase {
    let lib = Packs.library
    let stage = FunStage(entry: Vec2(100, 300), exit: Vec2(300, 300))

    func scenes(reducedMotion: Bool = false) -> [FunScene] {
        FunCommand.allCases.compactMap { FunCatalog.scene(for: $0, clips: lib, stage: stage, reducedMotion: reducedMotion) }
            + [FunCatalog.statueLost, FunCatalog.statueWon, FunCatalog.statueClicked]
    }

    func testEveryCommandHasASceneWithTheDefaultPack() {
        for c in FunCommand.allCases where c != .stop && c != .surprise {
            XCTAssertNotNil(FunCatalog.scene(for: c, clips: lib, stage: stage), c.rawValue)
        }
        XCTAssertNil(FunCatalog.scene(for: .stage, clips: lib, stage: nil), "sem janela, sem palco")
    }

    // Brincadeira nunca usa sinal de segurança nem o `split` do Multi-Glyph.
    func testScenesNeverUseSafetySignals() {
        let forbidden: Set<DotMode> = [.alert, .blink, .shrink, .split]
        for s in scenes() + scenes(reducedMotion: true) {
            for b in s.beats {
                XCTAssertFalse(PackLoader.protectedClips.contains(b.clip), b.clip)
                let mode = b.dot ?? lib[b.clip]?.dot?.mode
                XCTAssertFalse(mode.map(forbidden.contains) ?? false, "\(b.clip): \(String(describing: mode))")
            }
        }
    }

    func testScenesAreShortAndFinite() {
        let dance = FunCatalog.scene(for: .dance, clips: lib)!
        XCTAssertTrue((5...8).contains(dance.poseDuration), "\(dance.poseDuration)")
        for s in scenes() {
            XCTAssertLessThanOrEqual(s.poseDuration, FunMode.statueRound, "\(s.command)")
            for b in s.beats where b.bubble != nil {
                XCTAssertEqual(BubbleSay(text: b.bubble!).displayText, b.bubble, "bolha curta, sem corte")
            }
        }
    }

    func testDanceUsesTheExamplePackWhenInstalled() throws {
        var withPack = lib
        let url = Packs.defaultPack.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/pack-exemplo/clips/danca.json")
        withPack.add(try ClipLibrary.decode(Data(contentsOf: url)))
        XCTAssertEqual(FunCatalog.scene(for: .dance, clips: withPack)?.beats.first?.clip, "danca")
        XCTAssertEqual(FunCatalog.scene(for: .dance, clips: lib)?.beats.first?.clip, "groove")
    }

    func testMissingClipMeansNoScene() {
        XCTAssertNil(FunCatalog.scene(for: .robot, clips: ClipLibrary()))
    }

    func testReducedMotionKeepsOnlyAStillEnding() {
        for c in [FunCommand.dance, .trick, .stage] {
            let s = FunCatalog.scene(for: c, clips: lib, stage: nil, reducedMotion: true)!
            XCTAssertEqual(s.beats.count, 1, c.rawValue)
            XCTAssertFalse(s.beats[0].isGo)
            XCTAssertEqual(s.beats[0].turns, 0)
        }
        XCTAssertEqual(FunCatalog.scene(for: .trick, clips: lib, reducedMotion: true)?.beats[0].bubble, "ta-da!")
    }
}

final class FunStageTests: XCTestCase {
    func testPicksTheNearestWindowTopFromTheNearSide() {
        let w = TestWorlds.world([TestWorlds.win(1, 500, 300, 400, 200)])
        let s = FunStage.find(in: w, near: Vec2(520, 500))!
        XCTAssertEqual(s.entry, Vec2(524, 500))
        XCTAssertEqual(s.exit, Vec2(764, 500))
        let r = FunStage.find(in: w, near: Vec2(880, 500))!
        XCTAssertEqual(r.entry, Vec2(876, 500))
        XCTAssertEqual(r.exit, Vec2(636, 500))
    }

    func testNoWindowNoStage() {
        XCTAssertNil(FunStage.find(in: TestWorlds.world([]), near: Vec2(700, 80)))
        XCTAssertNil(FunStage.find(in: TestWorlds.world([TestWorlds.win(1, 500, 300, 80, 200)]), near: Vec2(520, 500)),
                     "janela estreita demais para desfilar")
    }
}

final class FunModeStateTests: XCTestCase {
    func testSurpriseNeverRepeatsTheLastShow() {
        var m = FunMode()
        var rng = SplitMix64(seed: 7)
        var last: FunCommand?
        for _ in 0..<40 {
            let c = m.pickSurprise(from: FunCatalog.surprises, rng: &rng)!
            XCTAssertNotEqual(c, last)
            m.play(FunScene(command: c, beats: [.pose("idle", 1)]), at: 0)
            last = c
        }
        XCTAssertEqual(m.pickSurprise(from: [.robot], rng: &rng), .robot, "com uma opção só, repete")
    }

    func testStatueCountsEachNewApproach() {
        var m = FunMode()
        m.play(FunCatalog.scene(for: .statue, clips: Packs.library)!, at: 0)
        m.markBegun(at: 0)
        m.cursor(distance: 30, at: 1)
        m.cursor(distance: 20, at: 1.2) // ainda perto: não conta de novo
        XCTAssertEqual(m.giggles, 1)
        XCTAssertTrue(m.shaking(at: 1.1))
        XCTAssertFalse(m.shaking(at: 1.6))
        m.cursor(distance: 200, at: 2)
        m.cursor(distance: 30, at: 2.1)
        XCTAssertEqual(m.giggles, 2)
    }

    func testSpinEndsOnTheSideItStarted() {
        var m = FunMode()
        m.play(FunScene(command: .dance, beats: [.pose("spin", 1, turns: 2)]), at: 0)
        m.markBegun(at: 0)
        let flips = stride(from: 0.0, to: 1.2, by: 0.05).map { m.flipped(at: $0) }
        XCTAssertTrue(flips.contains(true))
        XCTAssertFalse(m.flipped(at: 0.1))
        XCTAssertTrue(m.flipped(at: 0.3))
        XCTAssertFalse(m.flipped(at: 0.6))
        XCTAssertTrue(m.flipped(at: 0.8))
        XCTAssertFalse(m.flipped(at: 1.1), "duas voltas: termina do lado em que começou")
    }
}

final class FunEngineTests: XCTestCase {
    func engine(_ windows: [WindowInfo] = [], start: Vec2? = nil) -> GlyphEngine {
        GlyphEngine(world: WorldSnapshot(screens: [TestWorlds.screen], windows: windows), clips: Packs.library, start: start)
    }

    func run(_ e: inout GlyphEngine, seconds: Double, fps: Double = 30, each: ((inout GlyphEngine) -> Void)? = nil) {
        for _ in 0..<Int(seconds * fps) {
            e.advance(by: 1 / fps)
            _ = e.drawing
            each?(&e)
        }
    }

    func testNonCommandsAreLeftForTheBrain() {
        var e = engine()
        XCTAssertFalse(e.fun("roda os testes"))
        XCTAssertFalse(e.funMode.isOn)
    }

    func testDancePlaysLocallyThenWaitsOnStage() {
        var e = engine()
        run(&e, seconds: 1.5)
        let x = e.body.position.x
        XCTAssertTrue(e.fun("/danca"))
        XCTAssertTrue(e.funMode.isOn)
        XCTAssertEqual(e.drainEvents(), [], "nada vai ao cérebro")
        run(&e, seconds: 1)
        XCTAssertEqual(e.funMode.scene?.command, .dance)
        XCTAssertEqual(e.desiredFPS, 60)
        run(&e, seconds: 8)
        XCTAssertNil(e.funMode.scene, "apresentação finita")
        XCTAssertTrue(e.funMode.isOn)
        run(&e, seconds: 60)
        XCTAssertEqual(e.body.position.x, x, accuracy: 1, "no palco: sem passear")
    }

    func testSessionEndsAfterFiveMinutes() {
        var e = engine()
        run(&e, seconds: 1.5)
        XCTAssertTrue(e.fun("/diversao iniciar"))
        var saw = false
        run(&e, seconds: FunMode.sessionLength + 2, fps: 10) { e in
            if e.drawing?.bubble == "fim do recreio." { saw = true }
        }
        XCTAssertFalse(e.funMode.isOn)
        XCTAssertTrue(saw)
    }

    func testStopCommand() {
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/robo")
        run(&e, seconds: 0.5)
        XCTAssertTrue(e.fun("chega de brincar"))
        XCTAssertFalse(e.funMode.isOn)
        XCTAssertNil(e.funMode.scene)
    }

    // Aprovação, tarefa, alerta e freio vencem a brincadeira, sem cerimônia.
    func testRealSignalsEndTheGame() {
        let signals: [Message] = [
            .approvalRequest(ApprovalRequest(action: "git.push", target: "x", actionClass: .externalEffect, why: "abrir PR?", timeoutSec: 5)),
            .taskUpdate(TaskUpdate(taskId: "t", step: "testes", progress: 0.2)),
            .bodyEmote(BodyEmote(clip: "error")),
            .bodyEmote(BodyEmote(clip: "idle", dot: .alert)),
            .bodyGoto(BodyGoto(target: .home)),
        ]
        for m in signals {
            var e = engine()
            run(&e, seconds: 1.5)
            _ = e.fun("/danca")
            run(&e, seconds: 1)
            e.receive(m)
            XCTAssertFalse(e.funMode.isOn, "\(m.kind)")
        }
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/danca")
        e.receive(.bodyEmote(BodyEmote(clip: "wave")))
        XCTAssertTrue(e.funMode.isOn, "gesto comum do cérebro não interrompe")
    }

    func testBrakeCutsAndRefuses() {
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/truque")
        e.setBrake(true)
        XCTAssertFalse(e.funMode.isOn)
        XCTAssertTrue(e.fun("/danca"), "é comando: não vai ao cérebro")
        XCTAssertFalse(e.funMode.isOn)
        XCTAssertEqual(e.drawing?.bubble, "freio puxado.")
        e.setBrake(false)
        XCTAssertTrue(e.fun("/danca"))
        XCTAssertTrue(e.funMode.isOn)
    }

    func testPendingApprovalRefusesToPlay() {
        var e = engine()
        run(&e, seconds: 1.5)
        e.receive(.approvalRequest(ApprovalRequest(action: "a", target: "b", actionClass: .externalEffect, why: "ok?", timeoutSec: 30)))
        XCTAssertTrue(e.fun("/danca"))
        XCTAssertFalse(e.funMode.isOn)
    }

    func testStageWalksAlongTheWindowAndBows() {
        var e = engine([TestWorlds.win(1, 500, 300, 400, 200)], start: Vec2(650, 700))
        run(&e, seconds: 1.5)
        XCTAssertEqual(e.body.support, .ground(.window(1)))
        XCTAssertTrue(e.fun("/janela-palco"))
        var bubbles: Set<String> = []
        var maxX = 0.0
        run(&e, seconds: 25) { e in
            if let b = e.drawing?.bubble { bubbles.insert(b) }
            maxX = max(maxX, e.body.position.x)
        }
        XCTAssertNil(e.funMode.scene)
        XCTAssertTrue(bubbles.contains("obrigado!"), "\(bubbles)")
        XCTAssertFalse(bubbles.contains("sem palco aqui. tenta /danca"))
        XCTAssertEqual(maxX, 764, accuracy: 30, "desfilou até a saída")
        XCTAssertEqual(e.body.support, .ground(.window(1)))
    }

    func testStageWithoutWindowsSuggestsSomethingElse() {
        var e = engine()
        run(&e, seconds: 1.5)
        XCTAssertTrue(e.fun("/janela-palco"))
        XCTAssertNil(e.funMode.scene)
        XCTAssertEqual(e.drawing?.bubble, "sem palco aqui. tenta /danca")
    }

    func testStatueLaughsOnTheThirdTickle() {
        var e = engine()
        run(&e, seconds: 1.5)
        XCTAssertTrue(e.fun("/estatua"))
        run(&e, seconds: 1)
        let center = e.body.position + Vec2(0, 20)
        for _ in 0..<3 {
            e.setCursor(center + Vec2(300, 0))
            run(&e, seconds: 0.6)
            e.setCursor(center + Vec2(10, 0))
            run(&e, seconds: 0.6)
        }
        run(&e, seconds: 0.1)
        XCTAssertEqual(e.funMode.scene, FunCatalog.statueLost)
    }

    func testStatueWinsAfterTheRound() {
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/estatua")
        run(&e, seconds: FunMode.statueRound + 0.5)
        XCTAssertEqual(e.funMode.scene, FunCatalog.statueWon)
    }

    func testClickEndsTheStatueRound() {
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/estatua")
        run(&e, seconds: 1)
        let p = e.hitbox!.center
        e.mouseDown(at: p)
        e.mouseUp(at: p)
        XCTAssertEqual(e.funMode.scene, FunCatalog.statueClicked)
        XCTAssertEqual(e.drainEvents(), [], "clique na brincadeira não chama o cérebro")
    }

    func testSurpriseRunsAnAvailableScene() {
        var e = engine()
        run(&e, seconds: 1.5)
        XCTAssertTrue(e.fun("me surpreenda"))
        let c = e.funMode.scene?.command
        XCTAssertNotNil(c)
        XCTAssertNotEqual(c, .stage, "sem janela, o palco não entra no sorteio")
    }

    func testDraggingCutsTheShowButKeepsTheMode() {
        var e = engine()
        run(&e, seconds: 1.5)
        _ = e.fun("/robo")
        run(&e, seconds: 0.5)
        let p = e.hitbox!.center
        e.mouseDown(at: p)
        e.mouseDragged(to: p + Vec2(40, 40))
        run(&e, seconds: 0.1)
        XCTAssertNil(e.funMode.scene)
        XCTAssertTrue(e.funMode.isOn)
    }
}
