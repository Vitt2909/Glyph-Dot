import XCTest
@testable import GlyphCore

final class BehaviorTests: XCTestCase {
    func testEnergyDropsAndSleepRestores() {
        var n = Needs()
        for _ in 0..<600 { n.update(dt: 1, moving: true, sleeping: false, cursorNear: false) }
        XCTAssertLessThan(n.energy, 0.5)
        let low = n.energy
        for _ in 0..<60 { n.update(dt: 1, moving: false, sleeping: true, cursorNear: false) }
        XCTAssertGreaterThan(n.energy, low)
    }

    func testSociabilityRisesWithCursor() {
        var n = Needs()
        n.update(dt: 4, moving: false, sleeping: false, cursorNear: true)
        XCTAssertGreaterThan(n.sociability, 0.6)
        n.noticeEvent(novelty: 5)
        XCTAssertEqual(n.curiosity, 1)
    }

    func testHysteresisAvoidsFlipFlop() {
        var p = UtilityPicker()
        p.pick([.init(.idle, 0.5), .init(.sleep, 0.2)], dt: 3)
        XCTAssertEqual(p.current, .idle)
        // Ligeiramente melhor não basta.
        XCTAssertFalse(p.pick([.init(.idle, 0.5), .init(.sleep, 0.55)], dt: 3).changed)
        // Bem melhor, depois do tempo mínimo, troca.
        XCTAssertTrue(p.pick([.init(.idle, 0.5), .init(.sleep, 0.8)], dt: 3).changed)
        XCTAssertEqual(p.current, .sleep)
        // Logo depois de trocar, não volta mesmo se o outro for melhor.
        XCTAssertFalse(p.pick([.init(.idle, 0.95), .init(.sleep, 0.5)], dt: 0.25).changed)
    }

    func testForcedIgnoresDwell() {
        var p = UtilityPicker()
        p.force(.sleep)
        XCTAssertTrue(p.pick([.init(.sleep, 0.8), .init(.flee, 0.81, forced: true)], dt: 0.1).changed)
        XCTAssertEqual(p.current, .flee)
    }

    func testCursorVelocity() {
        var c = CursorTracker()
        c.add(Vec2(0, 0), at: 0)
        c.add(Vec2(50, 0), at: 0.1)
        c.add(Vec2(100, 0), at: 0.2)
        XCTAssertEqual(c.velocity.x, 500, accuracy: 1)
    }

    func testHoverOneSecondWaves() {
        var r = CursorReactor(), c = CursorTracker()
        let hitbox = Rect(x: 90, y: 80, width: 30, height: 50)
        var reactions: [CursorReaction] = []
        for i in 0...80 {
            let t = Double(i) / 60
            c.add(Vec2(100, 100), at: t)
            reactions.append(r.react(cursor: c, body: Vec2(105, 100), hitbox: hitbox, time: t))
        }
        XCTAssertEqual(reactions.filter { $0 == .wave }.count, 1, "acena uma vez só")
        XCTAssertEqual(reactions.first, .look(Vec2(100, 100)))
    }

    func testFastApproachRecoils() {
        var r = CursorReactor(), c = CursorTracker()
        let hitbox = Rect(x: 490, y: 80, width: 30, height: 50)
        var got: CursorReaction = .none
        for i in 0...12 {
            let t = Double(i) / 60
            c.add(Vec2(300 + Double(i) * 20, 100), at: t) // 1200 pt/s em direção a ele
            let x = r.react(cursor: c, body: Vec2(505, 100), hitbox: hitbox, time: t)
            if case .recoil = x { got = x }
        }
        XCTAssertEqual(got, .recoil(dir: 1), "recua para longe do cursor")
    }

    func testSlowApproachLooks() {
        var r = CursorReactor(), c = CursorTracker()
        c.add(Vec2(400, 100), at: 0)
        c.add(Vec2(401, 100), at: 0.2)
        XCTAssertEqual(r.react(cursor: c, body: Vec2(505, 100), hitbox: Rect(x: 490, y: 80, width: 30, height: 50), time: 0.2),
                       .look(Vec2(401, 100)))
    }
}
