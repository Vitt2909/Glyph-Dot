import XCTest
@testable import GlyphCore

final class PhysicsTests: XCTestCase {
    let sim = PhysicsSimulator()

    func standing(on kind: SurfaceKind, x: Double, y: Double) -> BodyState {
        var s = BodyState(position: Vec2(x, y))
        s.support = .ground(kind)
        s.lastSurface = kind
        return s
    }

    func testFallsAndLandsOnWindow() {
        let w = TestWorlds.world([TestWorlds.win(1, 200, 200, 400, 300)])
        var s = BodyState(position: Vec2(300, 800))
        let events = simulate(&s, in: w, seconds: 2)
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.y, 500, accuracy: 1e-9)
        XCTAssertTrue(events.contains { if case .landed(_, .window(1)) = $0 { return true }; return false })
    }

    func testClosingWindowDropsOntoWindowBelow() {
        let upper = TestWorlds.win(1, 250, 400, 300, 200)   // topo 600
        let lower = TestWorlds.win(2, 200, 150, 500, 200)   // topo 350
        var s = standing(on: .window(1), x: 400, y: 600)
        let closed = TestWorlds.world([lower])
        let events = simulate(&s, in: closed, seconds: 2)
        XCTAssertEqual(s.support, .ground(.window(2)), "pousa na janela de baixo")
        XCTAssertEqual(s.position.y, 350, accuracy: 1e-9)
        XCTAssertTrue(events.contains(.lostSupport))
        _ = upper
    }

    func testClosingOnlyWindowDropsOntoDock() {
        var s = standing(on: .window(1), x: 400, y: 600)
        simulate(&s, in: TestWorlds.world([]), seconds: 2)
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
        XCTAssertEqual(s.position.y, 80, accuracy: 1e-9)
    }

    func testDraggingWindowCarriesHim() {
        let before = WorldSnapshot(screens: [TestWorlds.screen], windows: [TestWorlds.win(1, 200, 200, 400, 300)])
        let after = WorldSnapshot(screens: [TestWorlds.screen], windows: [TestWorlds.win(1, 330, 150, 400, 300)])
        var s = standing(on: .window(1), x: 300, y: 500)
        sim.apply(WorldDiff.between(before, after), to: &s)
        XCTAssertEqual(s.position, Vec2(430, 450))
        simulate(&s, in: World(after), seconds: 0.5)
        XCTAssertEqual(s.support, .ground(.window(1)), "continua em cima")
        XCTAssertEqual(s.position, Vec2(430, 450))
    }

    func testWalkingOffTheEdgeFalls() {
        let w = TestWorlds.world([TestWorlds.win(1, 200, 200, 400, 300)])
        var s = standing(on: .window(1), x: 580, y: 500)
        var c = Control(); c.moveX = 1
        let events = simulate(&s, in: w, seconds: 3, control: c)
        XCTAssertTrue(events.contains(.leftGround(.window(1))))
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)))
    }

    func testOneWayPlatformFromBelow() {
        // Pula de baixo, atravessa o topo da janela e pousa em cima.
        let w = TestWorlds.world([TestWorlds.win(1, 200, 60, 400, 100)]) // topo 160
        var s = standing(on: .floor(screen: 1), x: 300, y: 80)
        var c = Control(); c.jump = Vec2(0, 600)
        _ = sim.step(&s, c, in: w)
        simulate(&s, in: w, seconds: 2)
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.y, 160, accuracy: 1e-9)
    }

    func testCoyoteTime() {
        let w = TestWorlds.world([TestWorlds.win(1, 200, 200, 400, 300)])
        var s = standing(on: .window(1), x: 599, y: 500)
        var walk = Control(); walk.moveX = 1
        while s.support.isGrounded { _ = sim.step(&s, walk, in: w) }
        XCTAssertLessThan(s.airTime, sim.config.coyoteTime)
        var jump = Control(); jump.jump = Vec2(50, 400)
        XCTAssertTrue(sim.step(&s, jump, in: w).contains(.jumped), "ainda pode pular logo depois da borda")
        simulate(&s, in: w, seconds: 0.2)
        XCTAssertFalse(sim.step(&s, jump, in: w).contains(.jumped), "mas não duas vezes no ar")
    }

    func testScreenEdgeStops() {
        let w = TestWorlds.world([])
        var s = BodyState(position: Vec2(30, 300))
        s.velocity = Vec2(-400, 0)
        let events = simulate(&s, in: w, seconds: 2)
        XCTAssertTrue(events.contains(.hitScreenEdge))
        XCTAssertGreaterThanOrEqual(s.position.x, BodyMetrics().halfWidth - 1e-9)
    }

    func testClimbAndMantle() {
        let win = TestWorlds.win(1, 400, 60, 300, 200) // lateral esquerda x=400, y 80…260 visível
        let w = TestWorlds.world([win])
        let key = WallKey(owner: .window(1), side: -1)
        var s = standing(on: .floor(screen: 1), x: 400 - 11, y: 80)
        var c = Control(); c.attachWall = key
        XCTAssertEqual(sim.step(&s, c, in: w), [.grabbedWall(key)])
        var up = Control(); up.climb = 1
        let events = simulate(&s, in: w, seconds: 5, control: up)
        XCTAssertTrue(events.contains(.mantled(.window(1))))
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.y, 260, accuracy: 1e-9)
    }

    func testCoveredByMaximizedWindowKeepsStandingUntilHeRuns() {
        let small = TestWorlds.win(2, 200, 200, 400, 300)
        let maxed = TestWorlds.win(1, 0, 80, 1440, 796)
        let w = TestWorlds.world([maxed, small])
        var s = standing(on: .window(2), x: 300, y: 500)
        simulate(&s, in: w, seconds: 0.2)
        XCTAssertEqual(s.support, .ground(.window(2)), "não despenca na hora")
        XCTAssertEqual(s.coveredBy, 1)
        var flee = Control(); flee.moveX = -1; flee.flee = true
        simulate(&s, in: w, seconds: 3, control: flee)
        XCTAssertEqual(s.support, .ground(.floor(screen: 1)), "correu até a borda e caiu no Dock")
    }

    func testReleaseClampsThrow() {
        var s = BodyState(position: Vec2(500, 500))
        s.support = .carried
        sim.release(&s, throwVelocity: Vec2(5000, 0))
        XCTAssertEqual(s.velocity.length, sim.config.maxThrow, accuracy: 1e-6)
        XCTAssertEqual(s.support, .air)
    }
}

final class JumpSolverTests: XCTestCase {
    let config = PhysicsConfig()

    func testSolvedJumpLandsOnTarget() {
        let a = Vec2(100, 80), b = Vec2(200, 150)
        let sol = JumpSolver.solve(from: a, to: b, config: config)!
        let end = JumpSolver.position(from: a, velocity: sol.velocity, gravity: config.gravity, at: sol.flightTime)
        XCTAssertEqual(end.x, b.x, accuracy: 1e-6)
        XCTAssertEqual(end.y, b.y, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(sol.velocity.y, config.maxJumpVy)
    }

    func testTooHighIsUnreachable() {
        XCTAssertNil(JumpSolver.solve(from: Vec2(0, 0), to: Vec2(10, config.maxJumpHeight + 1), config: config))
    }

    func testTooFarIsUnreachable() {
        XCTAssertNil(JumpSolver.solve(from: Vec2(0, 0), to: Vec2(2000, 0), config: config))
    }

    func testSimulatedJumpLandsOnPlatform() {
        // A física em passo fixo precisa concordar com a solução analítica.
        let w = TestWorlds.world([TestWorlds.win(1, 250, 60, 200, 100)]) // topo 160, x 250…450
        let sim = PhysicsSimulator()
        var s = BodyState(position: Vec2(190, 80))
        s.support = .ground(.floor(screen: 1))
        let sol = JumpSolver.solve(from: s.position, to: Vec2(280, 160), config: sim.config)!
        var c = Control(); c.jump = sol.velocity
        _ = sim.step(&s, c, in: w)
        simulate(&s, in: w, seconds: 2)
        XCTAssertEqual(s.support, .ground(.window(1)))
        XCTAssertEqual(s.position.x, 280, accuracy: 6)
    }
}
