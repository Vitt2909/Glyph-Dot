import XCTest
@testable import GlyphCore

final class CoexistenceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDismissalsReduceAndThreeInARowMuteForAWeek() {
        var c = Coexistence()
        c.dismissed(.dance, now: now)
        XCTAssertEqual(c.weight(.dance), 0.5)
        c.dismissed(.dance, now: now)
        XCTAssertFalse(c.isMuted(.dance, now: now))
        c.dismissed(.dance, now: now)
        XCTAssertTrue(c.isMuted(.dance, now: now))
        XCTAssertFalse(c.isMuted(.dance, now: now.addingTimeInterval(8 * 86_400)), "volta depois de uma semana")
        XCTAssertEqual(c.weight(.robot), 1, "as outras não mudam")
    }

    func testEnjoyingBreaksTheStreakAndRecovers() {
        var c = Coexistence()
        c.dismissed(.robot, now: now)
        c.dismissed(.robot, now: now)
        c.enjoyed(.robot)
        c.dismissed(.robot, now: now)
        XCTAssertFalse(c.isMuted(.robot, now: now))
        XCTAssertEqual(c.dismissStreak["robot"], 1)
    }

    func testPlayOnlyInPlayfulHoursUnlessBuilding() {
        var c = Coexistence()
        XCTAssertFalse(c.mayPlay(hour: 15, now: now, userIdle: 60, building: false), "ainda não sabe quando você gosta")
        XCTAssertTrue(c.mayPlay(hour: 15, now: now, userIdle: 0, building: true), "build rodando: pode")
        c.userPlayed(hour: 15)
        XCTAssertTrue(c.mayPlay(hour: 15, now: now, userIdle: 60, building: false))
        XCTAssertFalse(c.mayPlay(hour: 15, now: now, userIdle: 3, building: false), "você está digitando")
        XCTAssertFalse(c.mayPlay(hour: 9, now: now, userIdle: 60, building: false))
        c.spontaneous = false
        XCTAssertFalse(c.mayPlay(hour: 15, now: now, userIdle: 60, building: true), "desligado é desligado")
    }

    func testPickRespectsMutesAndWeights() {
        var c = Coexistence()
        for _ in 0..<3 { c.dismissed(.dance, now: now) }
        for u in stride(from: 0.0, to: 1, by: 0.05) {
            XCTAssertNotEqual(c.pick(u: u, now: now), .dance)
        }
        c.weights["robot"] = 0.1
        let picks = stride(from: 0.0, to: 1, by: 0.01).compactMap { c.pick(u: $0, now: now) }
        XCTAssertGreaterThan(picks.filter { $0 == .trick }.count, picks.filter { $0 == .robot }.count * 5)
    }

    func testFavoriteSpotIsTheMedianAfterThreePlacements() {
        var c = Coexistence()
        c.placed(fraction: 0.8)
        c.placed(fraction: 0.9)
        XCTAssertNil(c.favoriteSpot)
        c.placed(fraction: 0.1)
        XCTAssertEqual(c.favoriteSpot, 0.8)
    }

    func testPersistsAsJSON() throws {
        var c = Coexistence()
        c.dismissed(.trick, now: now)
        c.userPlayed(hour: 20)
        let back = try JSONDecoder().decode(Coexistence.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testMeetingAppsAndBuildCommands() {
        XCTAssertTrue(MeetingApps.contains("zoom.us"))
        XCTAssertFalse(MeetingApps.contains("Terminal"))
        XCTAssertFalse(MeetingApps.contains(nil))
        for b in ["swift build", "swift test --parallel", "npm run build", "cargo test", "make -j8", "pytest -q"] {
            XCTAssertTrue(BuildCommands.isBuild(b), b)
        }
        for n in ["ls", "git status", "makeitso", "vim Makefile"] { XCTAssertFalse(BuildCommands.isBuild(n), n) }
    }

    // MARK: - No motor

    func engine() -> GlyphEngine {
        var e = GlyphEngine(world: WorldSnapshot(screens: [TestWorlds.screen]), clips: Packs.library, start: Vec2(700, 200))
        for _ in 0..<60 { e.advance(by: 1.0 / 60); _ = e.drawing }
        return e
    }

    func run(_ e: inout GlyphEngine, _ seconds: Double) {
        for _ in 0..<Int(seconds * 30) { e.advance(by: 1.0 / 30); _ = e.drawing }
    }

    /// Sem relógio (a arte, os testes antigos), nada espontâneo acontece.
    func testNoClockNoSpontaneousPlay() {
        var e = engine()
        e.receive(.presenceHint(PresenceHint(state: .build, untilSec: 3600)))
        run(&e, 600)
        XCTAssertNil(e.spontaneous)
        XCTAssertFalse(e.funMode.isOn)
    }

    func testBuildLetsHimPlayAndClickTeachesHimToStop() {
        var e = engine()
        e.setClock(now)
        e.setUserIdle(0)
        e.receive(.presenceHint(PresenceHint(state: .build, untilSec: 3600)))
        XCTAssertTrue(e.isBuilding)
        var waited = 0.0
        while e.spontaneous == nil, waited < 3600 { run(&e, 5); waited += 5 }
        let c = try! XCTUnwrap(e.spontaneous, "com build rodando ele brinca, uma hora")
        _ = e.drainEvents()
        // Espera a cena começar e clica nele.
        run(&e, 1)
        let p = e.body.position + Vec2(0, 20)
        e.mouseDown(at: p); e.mouseUp(at: p)
        XCTAssertNil(e.spontaneous)
        XCTAssertFalse(e.funMode.isOn)
        XCTAssertEqual(e.coexistence.weight(c), 0.5, "dispensou: reduz")
        XCTAssertTrue(e.drainEvents().contains(.preferencesChanged))
    }

    func testMeetingSendsHimHome() {
        var e = engine()
        e.setMeeting(true)
        run(&e, 90)
        XCTAssertTrue(e.isHidden, "em reunião ele vai para casa")
        e.setMeeting(false)
        run(&e, 10)
        XCTAssertFalse(e.isHidden)
    }

    func testUserPlayMarksTheHour() {
        var e = engine()
        e.setClock(now)
        XCTAssertTrue(e.fun("/danca"))
        let h = Calendar.current.component(.hour, from: now)
        XCTAssertEqual(e.coexistence.playfulHours[h], 1)
        XCTAssertTrue(e.drainEvents().contains(.preferencesChanged))
    }

    func testCarryingAndDroppingTeachesTheSpot() {
        var e = engine()
        let grab = e.body.position + Vec2(0, 20)
        e.mouseDown(at: grab)
        for i in 1...20 {
            e.setCursor(grab + Vec2(Double(i) * 10, 0))
            e.mouseDragged(to: grab + Vec2(Double(i) * 10, 0))
            e.advance(by: 1.0 / 60)
        }
        e.mouseUp(at: grab + Vec2(200, 0))
        XCTAssertEqual(e.coexistence.spots.count, 1)
        XCTAssertEqual(e.coexistence.spots[0], (grab.x + 200) / 1440, accuracy: 0.01)
    }
}
