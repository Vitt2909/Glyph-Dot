import XCTest
@testable import GlyphCore

final class WorldTests: XCTestCase {
    func testCoordinateConversionRoundTrip() {
        let cg = Rect(x: 100, y: 50, width: 300, height: 200) // topo em y=50 no CG
        let ak = WorldCoordinates.fromCG(cg, primaryHeight: 900)
        XCTAssertEqual(ak.maxY, 850)
        XCTAssertEqual(ak.minY, 650)
        XCTAssertEqual(WorldCoordinates.toCG(ak, primaryHeight: 900), cg)
        XCTAssertEqual(WorldCoordinates.fromCG(Vec2(10, 0), primaryHeight: 900), Vec2(10, 900))
    }

    func testFloorCeilingAndHome() {
        let s = TestWorlds.screen
        XCTAssertEqual(s.floorY, 80, "Dock embaixo: o chão é o topo do Dock")
        XCTAssertEqual(s.ceilingY, 876)
        XCTAssertEqual(s.home.midX, 720, "sem notch: pílula no centro")
        var hidden = s
        hidden.visibleFrame = Rect(x: 0, y: 0, width: 1440, height: 876)
        XCTAssertEqual(hidden.floorY, 0, "Dock oculto: o chão é a borda da tela")
        XCTAssertEqual(TestWorlds.notched.home, TestWorlds.notched.notch, "com notch, a casa é a notch")
    }

    func testEmptyWorldHasFloorCeilingAndEdges() {
        let w = TestWorlds.world([])
        XCTAssertEqual(w.segments.count, 2)
        XCTAssertEqual(w.walls.filter(\.solid).count, 2)
    }

    func testOcclusionSplitsTopEdge() {
        // Janela 2 atrás; janela 1 na frente cobre o meio do topo dela.
        let front = TestWorlds.win(1, 400, 300, 200, 300)   // topo 600, cobre 300…600 em y
        let back = TestWorlds.win(2, 200, 200, 600, 300)    // topo em 500
        let w = TestWorlds.world([front, back])
        let tops = w.segments.filter { $0.kind == .window(2) }.sorted { $0.x0 < $1.x0 }
        XCTAssertEqual(tops.count, 2)
        XCTAssertEqual(tops[0].x0, 200); XCTAssertEqual(tops[0].x1, 400)
        XCTAssertEqual(tops[1].x0, 600); XCTAssertEqual(tops[1].x1, 800)
        XCTAssertEqual(w.segments.filter { $0.kind == .window(1) }.count, 1)
        XCTAssertEqual(w.rawTops[2]?.length, 600, "o topo cru ignora a oclusão")
    }

    func testFullyCoveredTopDisappears() {
        let front = TestWorlds.win(1, 100, 100, 800, 600)
        let back = TestWorlds.win(2, 200, 200, 300, 300)
        XCTAssertTrue(TestWorlds.world([front, back]).segments.filter { $0.kind == .window(2) }.isEmpty)
    }

    func testTinyVisiblePiecesAreDropped() {
        let front = TestWorlds.win(1, 210, 100, 580, 600)
        let back = TestWorlds.win(2, 200, 200, 600, 300) // sobram 10 pt de cada lado
        XCTAssertTrue(TestWorlds.world([front, back]).segments.filter { $0.kind == .window(2) }.isEmpty)
    }

    func testMaximizedWindowHasNoPlatform() {
        let max = TestWorlds.win(1, 0, 80, 1440, 796) // topo encosta na barra de menu
        XCTAssertTrue(TestWorlds.world([max]).segments.filter { $0.kind == .window(1) }.isEmpty)
    }

    func testWallsAreOccluded() {
        let front = TestWorlds.win(1, 100, 300, 200, 100) // cobre x=100…300, y=300…400
        let back = TestWorlds.win(2, 250, 200, 400, 400)  // lateral esquerda em x=250, y=200…600
        let walls = TestWorlds.world([front, back]).walls.filter { $0.key == WallKey(owner: .window(2), side: -1) }
        XCTAssertEqual(walls.map { Span($0.y0, $0.y1) }.sorted { $0.lo < $1.lo }, [Span(200, 300), Span(400, 600)])
    }

    func testAdjacentScreensHaveNoWallBetween() {
        let right = ScreenInfo(id: 2, frame: Rect(x: 1440, y: 0, width: 1920, height: 1080),
                               visibleFrame: Rect(x: 1440, y: 0, width: 1920, height: 1055), menuBarHeight: 25)
        let w = TestWorlds.world([], screens: [TestWorlds.screen, right])
        XCTAssertEqual(w.walls.filter(\.solid).map(\.x).sorted(), [0, 3360])
    }

    func testSegmentBelow() {
        let w = TestWorlds.world([TestWorlds.win(1, 200, 200, 400, 300)])
        XCTAssertEqual(w.segmentBelow(Vec2(300, 700))?.kind, .window(1))
        XCTAssertEqual(w.segmentBelow(Vec2(700, 700))?.kind, .floor(screen: 1))
        XCTAssertEqual(w.segmentBelow(Vec2(300, 400))?.kind, .floor(screen: 1), "abaixo do topo, a janela não conta")
    }

    func testDiff() {
        let a = WorldSnapshot(screens: [TestWorlds.screen], windows: [TestWorlds.win(1, 0, 0, 100, 100), TestWorlds.win(2, 0, 0, 100, 100)])
        let b = WorldSnapshot(screens: [TestWorlds.screen], windows: [TestWorlds.win(1, 50, 20, 100, 100), TestWorlds.win(3, 0, 0, 10, 10)])
        let d = WorldDiff.between(a, b)
        XCTAssertEqual(d.removed, [2])
        XCTAssertEqual(d.added, [3])
        XCTAssertEqual(Set(d.changed.keys), [1])
        XCTAssertFalse(d.screensChanged)
        XCTAssertTrue(WorldDiff.between(a, a).isEmpty)
        XCTAssertEqual(WorldDiff.topLeftDelta(old: a.windows[0].frame, new: b.windows[0].frame), Vec2(50, 20))
    }

    func testSpanSubtract() {
        XCTAssertEqual(Span.subtract(Span(0, 10), [Span(2, 3), Span(5, 20)]), [Span(0, 2), Span(3, 5)])
        XCTAssertEqual(Span.subtract(Span(0, 10), []), [Span(0, 10)])
        XCTAssertEqual(Span.subtract(Span(0, 10), [Span(-5, 50)]), [])
    }
}
