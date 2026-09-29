import XCTest
@testable import GlyphCore

final class SkeletonTests: XCTestCase {
    let m = SkeletonMetrics()

    func testLimbDirectionConvention() {
        let down = ForwardKinematics.limbDirection(0)
        XCTAssertEqual(down.x, 0, accuracy: 1e-9)
        XCTAssertEqual(down.y, -1, accuracy: 1e-9)
        let right = ForwardKinematics.limbDirection(90)
        XCTAssertEqual(right.x, 1, accuracy: 1e-9)
        XCTAssertEqual(right.y, 0, accuracy: 1e-9)
    }

    func testStraightPoseStandsOnGround() {
        var pose = Pose()
        for j in Joint.allCases { pose[j] = 0 }
        let p = ForwardKinematics.solve(pose, metrics: m)
        XCTAssertEqual(p.footL.y, 0, accuracy: 1e-9)
        XCTAssertEqual(p.footR.y, 0, accuracy: 1e-9)
        XCTAssertEqual(p.hip.y, m.legUpper + m.legLower, accuracy: 1e-9)
        XCTAssertEqual(p.headCenter.y + m.headRadius, m.height, accuracy: 1e-9)
    }

    func testWaveRaisesHand() {
        // Quadro do meio do clipe "wave" de docs/ANIMATION.md.
        var pose = Pose.rest
        pose[.armRUpper] = -150
        pose[.armRLower] = -30
        let p = ForwardKinematics.solve(pose, metrics: m)
        XCTAssertGreaterThan(p.handR.y, p.shoulder.y, "a mão sobe acima do ombro")
        XCTAssertLessThan(p.handR.x, 0, "braço direito anatômico fica à esquerda da tela")
    }

    func testFacingMirrors() {
        let a = ForwardKinematics.solve(.rest, metrics: m, facing: 1)
        let b = ForwardKinematics.solve(.rest, metrics: m, facing: -1)
        XCTAssertEqual(a.handR.x, -b.handR.x, accuracy: 1e-9)
        XCTAssertEqual(a.handR.y, b.handR.y, accuracy: 1e-9)
    }

    func testSquashKeepsFeetOnGround() {
        var pose = Pose.rest
        pose[.stretch] = 0.7
        let p = ForwardKinematics.solve(pose, metrics: m)
        let rest = ForwardKinematics.solve(.rest, metrics: m)
        XCTAssertLessThan(p.headCenter.y, rest.headCenter.y)
        XCTAssertEqual(min(p.footL.y, p.footR.y), min(rest.footL.y, rest.footR.y) * 0.7, accuracy: 1e-9)
    }

    func testPoseLerpAndMerge() {
        let a = Pose(["torso": 0]), b = Pose(["torso": 10])
        XCTAssertEqual(Pose.lerp(a, b, 0.5)[.torso], 5, accuracy: 1e-9)
        XCTAssertEqual(a.merging(b)[.torso], 10)
        XCTAssertEqual(Pose(["torso": 3]).adding(Pose(["torso": 2]))[.torso], 5)
        XCTAssertEqual(Pose(["stretch": 1.2]).adding(Pose(["stretch": 0.5]))[.stretch], 0.6, accuracy: 1e-9)
        XCTAssertEqual(Pose()[.armRUpper], Pose.rest[.armRUpper], "canal ausente vale o repouso")
    }
}

final class LineBoilTests: XCTestCase {
    func testDeterministicAndBounded() {
        let boil = LineBoil(seed: 7)
        for i in 0..<200 {
            let o = boil.offset(pointIndex: i, frame: i * 5)
            XCTAssertLessThanOrEqual(abs(o.x), 0.6 + 1e-12)
            XCTAssertLessThanOrEqual(abs(o.y), 0.6 + 1e-12)
            XCTAssertEqual(o, LineBoil(seed: 7).offset(pointIndex: i, frame: i * 5))
        }
    }

    func testChangesEveryThreeFrames() {
        let boil = LineBoil()
        XCTAssertEqual(boil.offset(pointIndex: 1, frame: 0), boil.offset(pointIndex: 1, frame: 2))
        XCTAssertNotEqual(boil.offset(pointIndex: 1, frame: 2), boil.offset(pointIndex: 1, frame: 3))
    }

    func testStyleNumbers() {
        let s = StickerStyle.default
        XCTAssertEqual(s.inkWidth, 2.5)
        XCTAssertEqual(s.outlineStrokeWidth, 8.5)
        XCTAssertEqual(s.poseFPS, 12)
    }
}

final class StickerShapesTests: XCTestCase {
    func testStandingDrawingShapes() {
        let d = GlyphDrawing.standing(at: Vec2(500, 80))
        let s = StickerShapes.build(d)
        XCTAssertEqual(s.strokes.count, 6, "tronco, 2 braços, 2 pernas, cabeça")
        XCTAssertEqual(s.fills.count, 1, "só a cabeça é preenchida")
        XCTAssertEqual(s.discs.count, 1, "só o Dot")
        XCTAssertEqual(s.discs[0].center, d.dot.center + d.position)
        // Subdivisão: o tronco (13 pt) vira vários pontos.
        XCTAssertGreaterThan(s.strokes[0].count, 3)
        // Fechado: primeiro == último.
        XCTAssertEqual(s.strokes[5].first, s.strokes[5].last)
    }

    func testBoundsCoverDrawing() {
        let d = GlyphDrawing.standing(at: Vec2(500, 80))
        let b = d.bounds
        XCTAssertTrue(b.contains(d.position))
        XCTAssertTrue(b.contains(d.skeleton.headCenter + d.position))
        XCTAssertLessThan(b.height, 60)
        for stroke in StickerShapes.build(d).strokes {
            for p in stroke { XCTAssertTrue(b.insetBy(dx: -1, dy: -1).contains(p)) }
        }
    }

    func testAlertAndSleepAddInkNotText() {
        var d = GlyphDrawing.standing(at: .zero)
        d.dot.alert = true
        d.dot.sleeping = true
        let s = StickerShapes.build(d)
        XCTAssertEqual(s.strokes.count, 6 + 1 + 3)
        XCTAssertEqual(s.discs.count, 2)
    }

    func testEyesAppearOnlyWhenSet() {
        var d = GlyphDrawing.standing(at: .zero)
        XCTAssertEqual(StickerShapes.build(d).strokes.count, 6)
        d.eyes = EyesDrawing(look: Vec2(1, 0))
        XCTAssertEqual(StickerShapes.build(d).strokes.count, 8)
    }

    func testSubdivide() {
        let pts = Polyline.subdivide([Vec2(0, 0), Vec2(10, 0)], maxSegment: 4)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts.last, Vec2(10, 0))
    }
}
