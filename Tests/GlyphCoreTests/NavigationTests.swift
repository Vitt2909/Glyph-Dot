import XCTest
@testable import GlyphCore

final class NavigationTests: XCTestCase {
    func onFloor(_ x: Double) -> BodyState {
        var s = BodyState(position: Vec2(x, 80))
        s.support = .ground(.floor(screen: 1))
        s.lastSurface = .floor(screen: 1)
        return s
    }

    func testJumpOntoLowWindow() {
        let w = TestWorlds.world([TestWorlds.win(1, 400, 40, 300, 120)]) // topo 160
        var s = onFloor(200)
        let steps = NavGraph(world: w).path(from: s, to: .surface(.window(1), x: 550))!
        XCTAssertTrue(steps.contains { if case .jump = $0.move { return true }; return false })
        XCTAssertTrue(travel(&s, to: .surface(.window(1), x: 550), in: w))
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.x, 550, accuracy: 2)
    }

    func testClimbTallWindow() {
        let w = TestWorlds.world([TestWorlds.win(1, 600, 100, 300, 400)]) // lateral 100…500, topo 500
        var s = onFloor(200)
        let steps = NavGraph(world: w).path(from: s, to: .surface(.window(1), x: 750))!
        XCTAssertTrue(steps.contains { if case .climb = $0.move { return true }; return false }, "\(steps.map(\.move))")
        XCTAssertTrue(travel(&s, to: .surface(.window(1), x: 750), in: w))
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.y, 500, accuracy: 1e-6)
    }

    func testDropFromWindowToFloor() {
        let w = TestWorlds.world([TestWorlds.win(1, 600, 100, 300, 400)])
        var s = BodyState(position: Vec2(700, 500))
        s.support = .ground(.window(1))
        XCTAssertTrue(travel(&s, to: .surface(.floor(screen: 1), x: 200), in: w))
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
        XCTAssertEqual(s.position.x, 200, accuracy: 2)
    }

    func testJumpAcrossGapBetweenWindows() {
        let a = TestWorlds.win(1, 100, 100, 300, 300) // topo 400, x 100…400
        let b = TestWorlds.win(2, 480, 120, 300, 300) // topo 420, x 480…780
        let w = TestWorlds.world([a, b])
        var s = BodyState(position: Vec2(200, 400))
        s.support = .ground(.window(1))
        XCTAssertTrue(travel(&s, to: .surface(.window(2), x: 700), in: w))
        XCTAssertEqual(s.support, .ground(.window(2)))
    }

    func testGoHome() {
        let w = TestWorlds.world([TestWorlds.win(1, 300, 200, 400, 300)])
        var s = onFloor(900)
        XCTAssertTrue(travel(&s, to: .home(screen: 1), in: w, maxSeconds: 120))
        XCTAssertEqual(s.support, .ceiling(screen: 1))
        XCTAssertEqual(s.position.x, TestWorlds.screen.home.midX, accuracy: 2)
    }

    func testReachFloatingWindowFromCeiling() {
        // Janela alta e isolada: só dá para chegar vindo de cima.
        let w = TestWorlds.world([TestWorlds.win(1, 600, 500, 300, 200)]) // topo 700
        var s = onFloor(200)
        XCTAssertTrue(travel(&s, to: .surface(.window(1), x: 750), in: w, maxSeconds: 120))
        XCTAssertEqual(s.support, .ground(.window(1)))
    }

    func testPointGoalPrefersSurfaceBelow() {
        let w = TestWorlds.world([TestWorlds.win(1, 600, 100, 300, 400)])
        let g = NavGraph(world: w)
        let node = g.resolve(.point(Vec2(700, 520)))!
        XCTAssertEqual(w.segments[node.seg].kind, .window(1))
    }

    func testStartEqualsGoalIsEmpty() {
        let w = TestWorlds.world([])
        XCTAssertEqual(NavGraph(world: w).path(from: onFloor(300), to: .surface(.floor(screen: 1), x: 300)), [])
    }

    func testFollowerFailsWhenKnockedOff() {
        let w = TestWorlds.world([TestWorlds.win(1, 600, 100, 300, 400)])
        var s = BodyState(position: Vec2(700, 500))
        s.support = .ground(.window(1))
        var f = PathFollower(steps: [PathStep(move: .walk, from: Vec2(700, 500), to: Vec2(800, 500), surface: .window(1))])
        s.support = .air
        XCTAssertEqual(f.control(for: s, world: w, config: PhysicsConfig()).1, .failed)
    }

    func testHeapOrders() {
        var h = MinHeap<Int>()
        for (v, p) in [(3, 3.0), (1, 1.0), (2, 2.0), (0, 0.5)] { h.push(v, priority: p) }
        XCTAssertEqual([h.pop(), h.pop(), h.pop(), h.pop(), h.pop()], [0, 1, 2, 3, nil])
    }

    func testManyWindowsStaysFast() {
        var wins: [WindowInfo] = []
        var rng = SplitMix64(seed: 42)
        for i in 0..<25 {
            wins.append(TestWorlds.win(UInt32(i + 1), rng.nextUnit() * 1100, 80 + rng.nextUnit() * 500,
                                       200 + rng.nextUnit() * 300, 150 + rng.nextUnit() * 200))
        }
        let w = TestWorlds.world(wins)
        let start = Date()
        let g = NavGraph(world: w)
        _ = g.path(from: onFloor(100), to: .home(screen: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "reconstruir e planejar precisa ser barato")
    }
}
