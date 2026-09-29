import XCTest
@testable import GlyphCore

final class EngineTests: XCTestCase {
    func snapshot(_ windows: [WindowInfo]) -> WorldSnapshot {
        WorldSnapshot(screens: [TestWorlds.screen], windows: windows)
    }

    func engine(_ windows: [WindowInfo] = [], start: Vec2? = nil) -> GlyphEngine {
        GlyphEngine(world: snapshot(windows), clips: Packs.library, start: start)
    }

    func run(_ e: inout GlyphEngine, seconds: Double, fps: Double = 60, each: ((inout GlyphEngine) -> Void)? = nil) {
        for _ in 0..<Int(seconds * fps) {
            e.advance(by: 1 / fps)
            _ = e.drawing
            each?(&e)
        }
    }

    func testFallsToTheDockAndDraws() {
        var e = engine()
        run(&e, seconds: 1.5)
        XCTAssertEqual(e.body.support, .ground(.floor(screen: 1)))
        XCTAssertEqual(e.body.position.y, 80, accuracy: 1e-9)
        let d = e.drawing!
        XCTAssertEqual(d.position, e.body.position)
        XCTAssertTrue(d.bounds.contains(d.position))
    }

    // Aceite do M1: fechar a janela onde ele está → cai e pousa na de baixo.
    func testClosingWindowDropsOntoWindowBelow() {
        let upper = TestWorlds.win(1, 500, 400, 300, 200)
        let lower = TestWorlds.win(2, 400, 150, 600, 150)
        var e = engine([upper, lower], start: Vec2(650, 700))
        run(&e, seconds: 1)
        XCTAssertEqual(e.body.support, .ground(.window(1)))
        e.setWorld(snapshot([lower]))
        run(&e, seconds: 1)
        XCTAssertEqual(e.body.support.surface, .window(2))
    }

    // … ou no Dock, se não houver janela abaixo.
    func testClosingOnlyWindowDropsOntoDock() {
        let w = TestWorlds.win(1, 500, 400, 300, 200)
        var e = engine([w], start: Vec2(650, 700))
        run(&e, seconds: 1)
        e.setWorld(snapshot([]))
        run(&e, seconds: 1.5)
        XCTAssertEqual(e.body.support.surface, .floor(screen: 1))
    }

    // Aceite do M1: arrastar a janela → ele vai junto.
    func testDraggingWindowCarriesHim() {
        var e = engine([TestWorlds.win(1, 500, 400, 300, 200)], start: Vec2(650, 700))
        run(&e, seconds: 1)
        let before = e.body.position
        for i in 1...30 {
            e.setWorld(snapshot([TestWorlds.win(1, 500 + Double(i) * 5, 400 - Double(i) * 2, 300, 200)]))
            e.advance(by: 1.0 / 60)
        }
        XCTAssertEqual(e.body.support.surface, .window(1))
        XCTAssertEqual(e.body.position.y, before.y - 60, accuracy: 1e-6)
        XCTAssertEqual(e.body.position.x - before.x, 150, accuracy: 20, "herda o deslocamento (e ainda pode andar um pouco)")
    }

    // Aceite do M1: maximizar → ele corre para não ser empurrado.
    func testMaximizeMakesHimRun() {
        let small = TestWorlds.win(2, 500, 300, 300, 200)
        var e = engine([small], start: Vec2(650, 600))
        run(&e, seconds: 1)
        XCTAssertEqual(e.body.support.surface, .window(2))
        e.setWorld(snapshot([TestWorlds.win(2, 0, 80, 1440, 796)]))
        run(&e, seconds: 0.3)
        XCTAssertEqual(e.intent, .flee)
        XCTAssertGreaterThan(abs(e.body.velocity.x), PhysicsConfig().runSpeed, "corre de verdade")
    }

    func testMaximizeOverAnotherWindowEscapes() {
        let small = TestWorlds.win(2, 500, 300, 300, 200)
        var e = engine([small], start: Vec2(650, 600))
        run(&e, seconds: 1)
        e.setWorld(snapshot([TestWorlds.win(1, 0, 80, 1440, 796), small]))
        run(&e, seconds: 3)
        XCTAssertNil(e.body.coveredBy)
        XCTAssertEqual(e.body.support.surface, .floor(screen: 1), "saiu de baixo da janela e caiu no Dock")
    }

    func testGotoHomeHidesAndStopsDrawing() {
        var e = engine([TestWorlds.win(1, 300, 200, 400, 300)], start: Vec2(900, 200))
        run(&e, seconds: 1)
        e.receive(.bodyGoto(BodyGoto(target: .home)))
        run(&e, seconds: 90, fps: 30)
        XCTAssertTrue(e.isHidden, "entrou em casa; intent=\(e.intent) support=\(e.body.support)")
        XCTAssertNil(e.drawing)
        XCTAssertEqual(e.desiredFPS, 0, "0 fps quando oculto")
    }

    func testFullscreenSendsHimHomeAndBack() {
        var e = engine([], start: Vec2(700, 200))
        run(&e, seconds: 1)
        e.setFullscreen(true)
        run(&e, seconds: 90, fps: 30)
        XCTAssertTrue(e.isHidden)
        e.setFullscreen(false)
        run(&e, seconds: 10, fps: 30)
        XCTAssertFalse(e.isHidden)
    }

    func testCarryAndDrop() {
        var e = engine([], start: Vec2(700, 200))
        run(&e, seconds: 1)
        let grab = e.body.position + Vec2(0, 20)
        e.setCursor(grab)
        e.mouseDown(at: grab)
        for i in 1...20 {
            e.mouseDragged(to: grab + Vec2(Double(i) * 3, Double(i) * 15))
            e.advance(by: 1.0 / 60)
        }
        XCTAssertEqual(e.body.support, .carried)
        XCTAssertEqual(e.locomotion, .carried)
        XCTAssertEqual(e.body.position.y, 80 + 300, accuracy: 1e-6, "segue o cursor")
        e.mouseUp(at: grab + Vec2(60, 300))
        run(&e, seconds: 2)
        XCTAssertEqual(e.body.support.surface, .floor(screen: 1), "cai e levanta")
    }

    func testClickShowsBubbleAndSummons() {
        var e = engine([], start: Vec2(700, 200))
        run(&e, seconds: 1)
        let p = e.body.position + Vec2(0, 20)
        e.mouseDown(at: p)
        e.mouseUp(at: p)
        XCTAssertEqual(e.drawing?.bubble, "oi.")
        XCTAssertTrue(e.drainEvents().contains(.send(.inputSummon(InputSummon(source: .click)))))
        run(&e, seconds: 5)
        XCTAssertNil(e.drawing?.bubble, "a bolha some em 4 s")
    }

    func testDoubleClickOpensHome() {
        var e = engine([], start: Vec2(700, 200))
        run(&e, seconds: 1)
        let p = e.body.position + Vec2(0, 20)
        e.mouseDown(at: p); e.mouseUp(at: p)
        e.advance(by: 0.1)
        e.mouseDown(at: p); e.mouseUp(at: p)
        XCTAssertTrue(e.drainEvents().contains(.openHome))
    }

    func testClickOutsideDoesNothing() {
        var e = engine([], start: Vec2(700, 200))
        run(&e, seconds: 1)
        e.mouseDown(at: Vec2(100, 500)); e.mouseUp(at: Vec2(100, 500))
        XCTAssertTrue(e.drainEvents().isEmpty)
    }

    func testRestingUsesTwelveFPS() {
        var e = engine([], start: Vec2(700, 90))
        e.needs.curiosity = 0
        run(&e, seconds: 1)
        XCTAssertEqual(e.locomotion, .stand)
        XCTAssertEqual(e.desiredFPS, 12)
    }

    func testGetsSleepyAndSleeps() {
        var e = engine([], start: Vec2(700, 90))
        run(&e, seconds: 1)
        e.needs.energy = 0.05
        run(&e, seconds: 8, fps: 30)
        XCTAssertEqual(e.intent, .sleep)
        XCTAssertEqual(e.drawing?.dot.sleeping, true)
        XCTAssertLessThan(e.desiredFPS, 12)
    }

    func testBrainMessages() {
        var e = engine([], start: Vec2(700, 90))
        run(&e, seconds: 1)
        e.receive(.bubbleSay(BubbleSay(text: String(repeating: "x", count: 80))))
        XCTAssertEqual(e.drawing?.bubble?.count, BubbleSay.maxLength)
        e.receive(.taskUpdate(TaskUpdate(taskId: "t", step: "s", progress: 0.2, budgetRemaining: 3)))
        XCTAssertEqual(e.drawing?.budgetDots, 3)
        e.receive(.bodyEmote(BodyEmote(clip: "think", dot: .orbit)))
        run(&e, seconds: 0.5)
        XCTAssertFalse(e.drawing!.dot.particles.isEmpty, "pensando: o Dot orbita")
        e.receive(.approvalRequest(ApprovalRequest(action: "git.push", target: "x", actionClass: .externalEffect, why: "abrir PR?", timeoutSec: 5)))
        run(&e, seconds: 0.5)
        XCTAssertEqual(e.intent, .awaitApproval)
        run(&e, seconds: 6)
        XCTAssertNotEqual(e.intent, .awaitApproval, "timeout: o pedido expira")
    }

    func testGotoWindowWalksThere() {
        let w = TestWorlds.win(1, 900, 40, 300, 120) // topo 160
        var e = engine([w], start: Vec2(200, 90))
        run(&e, seconds: 1)
        e.receive(.bodyGoto(BodyGoto(target: .window(pid: 101, frame: w.frame))))
        run(&e, seconds: 8, fps: 30)
        XCTAssertEqual(e.body.support.surface, .window(1))
        XCTAssertEqual(e.body.position.x, 1050, accuracy: 30)
    }

    /// Dez minutos de vida com o mundo mudando: nada de NaN, nada fora da tela,
    /// e barato o bastante para caber no orçamento de CPU.
    func testLongLifeStaysSaneAndCheap() {
        var rng = SplitMix64(seed: 7)
        var windows: [WindowInfo] = (1...6).map { i in
            TestWorlds.win(UInt32(i), rng.nextUnit() * 1100, 80 + rng.nextUnit() * 450,
                           200 + rng.nextUnit() * 300, 120 + rng.nextUnit() * 250)
        }
        var e = engine(windows)
        let start = Date()
        let seconds = 600.0, fps = 30.0
        for i in 0..<Int(seconds * fps) {
            if i % 90 == 0 {
                // Mexe, fecha e abre janelas.
                let k = Int(rng.nextUnit() * Double(windows.count))
                if rng.nextUnit() < 0.2, windows.count > 2 {
                    windows.remove(at: k)
                } else if rng.nextUnit() < 0.3 {
                    windows.insert(TestWorlds.win(UInt32(100 + i), rng.nextUnit() * 1100, 80 + rng.nextUnit() * 450, 300, 200), at: 0)
                } else {
                    windows[k].frame = windows[k].frame.offsetBy(Vec2(rng.nextUnit() * 60 - 30, rng.nextUnit() * 40 - 20))
                }
                e.setWorld(snapshot(windows))
            }
            if i % 7 == 0 { e.setCursor(Vec2(rng.nextUnit() * 1440, rng.nextUnit() * 900)) }
            e.advance(by: 1 / fps)
            let d = e.drawing
            let p = e.body.position
            XCTAssertFalse(p.x.isNaN || p.y.isNaN)
            XCTAssertGreaterThanOrEqual(p.x, -1)
            XCTAssertLessThanOrEqual(p.x, 1441)
            XCTAssertGreaterThanOrEqual(p.y, 79)
            XCTAssertLessThanOrEqual(p.y, 900)
            if let d { XCTAssertFalse(d.skeleton.allPoints.contains { $0.x.isNaN || $0.y.isNaN }) }
        }
        let elapsed = Date().timeIntervalSince(start)
        // Build de debug em Linux; em release é bem mais rápido.
        XCTAssertLessThan(elapsed / seconds, 0.05, "motor gasta \(elapsed / seconds * 100)% de um núcleo")
    }
}

final class HeldStickerTests: XCTestCase {
    func testApprovalHoldsTheCardAndEmoteHoldsSticker() {
        let (stickers, _) = Sticker.load(pack: Packs.defaultPack)
        var e = GlyphEngine(world: WorldSnapshot(screens: [TestWorlds.screen]), clips: Packs.library,
                            stickers: stickers, start: Vec2(700, 90))
        for _ in 0..<60 { e.advance(by: 1.0 / 60) }
        XCTAssertNil(e.drawing?.held)
        e.receive(.approvalRequest(ApprovalRequest(action: "a", target: "b", actionClass: .externalEffect, why: "ok?", timeoutSec: 3)))
        e.advance(by: 0.3)
        XCTAssertEqual(e.drawing?.held?.id, "cartao")
        for _ in 0..<240 { e.advance(by: 1.0 / 60) }
        e.receive(.bodyEmote(BodyEmote(clip: "idle", sticker: "folha")))
        XCTAssertEqual(e.drawing?.held?.id, "folha")
        let d = e.drawing!
        XCTAssertGreaterThan(StickerShapes.build(d).strokes.count, StickerShapes.build(GlyphDrawing.standing(at: .zero)).strokes.count)
    }
}
