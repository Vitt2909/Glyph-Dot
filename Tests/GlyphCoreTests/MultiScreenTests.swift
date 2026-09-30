import XCTest
@testable import GlyphCore

/// Viagem entre monitores (proposta 0002, ideia 9).
final class MultiScreenTests: XCTestCase {
    /// Tela sem Dock: chão em `y`, teto 24 abaixo do topo.
    func screen(_ id: UInt32, x: Double, y: Double = 0, w: Double = 1440, h: Double = 900) -> ScreenInfo {
        ScreenInfo(id: id, frame: Rect(x: x, y: y, width: w, height: h),
                   visibleFrame: Rect(x: x, y: y, width: w, height: h - 24), menuBarHeight: 24)
    }

    func standing(_ x: Double, _ y: Double, on kind: SurfaceKind) -> BodyState {
        var s = BodyState(position: Vec2(x, y))
        s.support = .ground(kind)
        s.lastSurface = kind
        return s
    }

    func moves(_ w: World, from s: BodyState, to goal: NavGoal) -> [Move] {
        NavGraph(world: w).path(from: s, to: goal)?.map(\.move) ?? []
    }

    func testSameHeightScreensAreOneFloor() {
        let w = TestWorlds.world([], screens: [screen(1, x: 0), screen(2, x: 1440)])
        XCTAssertTrue(w.walls.filter { $0.x == 1440 }.isEmpty, "sem parede na emenda")
        XCTAssertEqual(w.passages.filter(\.isSide).count, 4, "chão e teto, nos dois sentidos")

        var s = standing(1200, 0, on: .floor(screen: 1))
        let m = moves(w, from: s, to: .surface(.floor(screen: 2), x: 1800))
        XCTAssertTrue(m.contains(.pass(.right)), "\(m)")
        XCTAssertFalse(m.contains { if case .jump = $0 { return true }; if case .drop = $0 { return true }; return false },
                       "anda pela emenda, sem pular nem cair: \(m)")
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 2), x: 1800), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 2)))
        XCTAssertEqual(s.position.x, 1800, accuracy: 2)

        // E volta.
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 1), x: 300), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }

    func testWalkingAcrossTheSeamNeverFalls() {
        let w = TestWorlds.world([], screens: [screen(1, x: 0), screen(2, x: 1440)])
        var s = standing(1400, 0, on: .floor(screen: 1))
        var c = Control()
        c.moveX = 1
        let events = simulate(&s, in: w, seconds: 2, control: c)
        XCTAssertTrue(events.contains(.crossedScreen(from: .floor(screen: 1), to: .floor(screen: 2))))
        XCTAssertFalse(events.contains { if case .leftGround = $0 { return true }; return false }, "\(events)")
        XCTAssertEqual(s.support, .ground(.floor(screen: 2)))
    }

    func testHangingCrossesToTheNeighborsCeiling() {
        let w = TestWorlds.world([], screens: [screen(1, x: 0), screen(2, x: 1440)])
        var s = BodyState(position: Vec2(1300, 876 - BodyMetrics().height))
        s.support = .ceiling(screen: 1)
        XCTAssertTrue(travel(&s, to: .home(screen: 2), in: w))
        XCTAssertEqual(s.support, .ceiling(screen: 2))
    }

    /// Monitores de alturas diferentes alinhados por cima: o chão da vizinha
    /// fica acima. Ele escala o degrau e sobe nela; para voltar, desce.
    func testTallStepBetweenScreensIsClimbed() {
        let low = screen(1, x: 0, y: 0, w: 1440, h: 1200)   // chão 0, teto 1176
        let high = screen(2, x: 1440, y: 300, w: 1440, h: 900) // chão 300, teto 1176
        let w = TestWorlds.world([], screens: [low, high])
        let step = w.walls.first { $0.key == WallKey(owner: .screen(1), side: 1) }
        XCTAssertEqual(step.map { Span($0.y0, $0.y1) }, Span(0, 300))
        XCTAssertEqual(step?.ledge, .floor(screen: 2))

        var s = standing(1000, 0, on: .floor(screen: 1))
        let m = moves(w, from: s, to: .surface(.floor(screen: 2), x: 2000))
        XCTAssertTrue(m.contains { if case .climb = $0 { return true }; return false }, "\(m)")
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 2), x: 2000), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 2)))
        XCTAssertEqual(s.position.y, 300, accuracy: 1e-6)

        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 1), x: 600), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }

    func testStepWallBlocksWalkingIntoTheVoid() {
        let w = TestWorlds.world([], screens: [screen(1, x: 0, w: 1440, h: 1200), screen(2, x: 1440, y: 300)])
        var s = standing(1400, 0, on: .floor(screen: 1))
        var c = Control()
        c.moveX = 1
        let events = simulate(&s, in: w, seconds: 1, control: c)
        XCTAssertTrue(events.contains(.hitScreenEdge))
        XCTAssertLessThan(s.position.x, 1440)
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }

    /// Uma tela em cima da outra: sobe pelo vão entre o teto de baixo e o chão
    /// de cima, e desce pelo mesmo caminho.
    func testStackedScreens() {
        let bottom = screen(1, x: 0, y: 0), top = screen(2, x: 200, y: 900, w: 1200)
        let w = TestWorlds.world([], screens: [bottom, top])
        XCTAssertEqual(w.passages.filter { !$0.isSide }.map(\.direction).sorted { $0.rawValue < $1.rawValue }, [.down, .up])

        var s = standing(300, 0, on: .floor(screen: 1))
        let m = moves(w, from: s, to: .surface(.floor(screen: 2), x: 900))
        XCTAssertTrue(m.contains(.pass(.up)), "\(m)")
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 2), x: 900), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 2)))
        XCTAssertEqual(s.position.y, 900, accuracy: 1e-6)

        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 1), x: 100), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }

    func testStackedScreensWithoutOverlapHaveNoPassage() {
        let w = TestWorlds.world([], screens: [screen(1, x: 0), screen(2, x: 1440, y: 900)])
        XCTAssertTrue(w.passages.isEmpty)
    }

    /// A emenda antiga (mesma altura, só o Dock diferente) continua dando para
    /// descer do chão alto para o baixo.
    func testDockStepStillDropsDown() {
        let right = ScreenInfo(id: 2, frame: Rect(x: 1440, y: 0, width: 1920, height: 1080),
                               visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1055), menuBarHeight: 25)
        let w = TestWorlds.world([], screens: [TestWorlds.screen, right])
        var s = standing(1300, 80, on: .floor(screen: 1))
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 2), x: 2000), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 2)))
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 1), x: 700), in: w), "sobe o degrau do Dock")
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }
}
