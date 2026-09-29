import XCTest
@testable import GlyphCore

enum Packs {
    static var defaultPack: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packs/default", isDirectory: true)
    }

    static let library: ClipLibrary = {
        let (lib, errors) = ClipLibrary.load(pack: defaultPack)
        precondition(errors.isEmpty, "\(errors)")
        return lib
    }()
}

final class PackTests: XCTestCase {
    func testDefaultPackLoadsWithoutErrors() {
        let (lib, errors) = ClipLibrary.load(pack: Packs.defaultPack)
        XCTAssertEqual(errors, [])
        XCTAssertGreaterThanOrEqual(lib.clips.count, 20)
    }

    func testEngineClipsExist() {
        let needed = ["idle", "walk", "run", "crouch", "jump", "fall", "land", "climb", "hang", "hang-move",
                      "carried", "wave", "look", "recoil", "await", "yawn", "sit", "sleep", "stand-up", "error", "think"]
        for id in needed { XCTAssertNotNil(Packs.library[id], id) }
    }

    func testWaveFollowsThePlanFormat() {
        let wave = Packs.library["wave"]!
        XCTAssertEqual(wave.keys.map(\.t), [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(wave.dot, ClipDot(mode: .pulse, speed: 1.5))
        // No meio do aceno, a mão fica acima do ombro e fora da cabeça.
        let p = ForwardKinematics.solve(wave.sample(at: 0.34))
        XCTAssertGreaterThan(p.handR.y, p.shoulder.y + 8)
        XCTAssertGreaterThan(p.handR.distance(to: p.headCenter), p.headRadius + 2)
    }

    func testHangingHandsReachAboveTheHead() {
        let p = ForwardKinematics.solve(Packs.library["hang"]!.sample(at: 0))
        XCTAssertGreaterThan(min(p.handL.y, p.handR.y), p.headCenter.y + p.headRadius - 0.5)
        XCTAssertGreaterThan(p.handL.distance(to: p.headCenter), p.headRadius + 2)
    }
}

final class ClipTests: XCTestCase {
    let clip = Clip(id: "t", fps: 12, loop: false, keys: [
        ClipKey(t: 0, pose: ["torso": 0]),
        ClipKey(t: 1, pose: ["torso": 12]),
    ])

    func testSampledOnTwelveFPS() {
        // 0,09 s e 0,16 s caem no mesmo quadro de 12 fps (1/12 ≈ 0,083).
        XCTAssertEqual(clip.sample(at: 0.09)[.torso], clip.sample(at: 0.16)[.torso])
        XCTAssertNotEqual(clip.sample(at: 0.16)[.torso], clip.sample(at: 0.17)[.torso])
        XCTAssertEqual(clip.sample(at: 0.5)[.torso], 6, accuracy: 1e-9)
        XCTAssertEqual(clip.sample(at: 0.5, quantize: false)[.torso], 6, accuracy: 1e-9)
    }

    func testHoldsLastKeyWhenNotLooping() {
        XCTAssertEqual(clip.sample(at: 5)[.torso], 12)
    }

    func testLoopWrapsBackToFirstKey() {
        var c = clip
        c.loop = true
        XCTAssertEqual(c.duration, 2)
        XCTAssertEqual(c.sample(at: 1.5, quantize: false)[.torso], 6, accuracy: 1e-9)
        XCTAssertEqual(c.sample(at: 2.5, quantize: false)[.torso], 6, accuracy: 1e-9)
    }

    func testEasing() {
        for e in [Ease.linear, .in, .out, .inOut] {
            XCTAssertEqual(e.apply(0), 0, accuracy: 1e-12)
            XCTAssertEqual(e.apply(1), 1, accuracy: 1e-12)
        }
        XCTAssertLessThan(Ease.in.apply(0.5), 0.5)
        XCTAssertGreaterThan(Ease.out.apply(0.5), 0.5)
        XCTAssertEqual(Ease.step.apply(0.9), 0)
    }

    func testMissingChannelsUseRest() {
        XCTAssertEqual(clip.sample(at: 0)[.armRUpper], Pose.rest[.armRUpper])
    }

    func testValidation() {
        XCTAssertThrowsError(try Clip(id: "Bad Id", keys: [ClipKey(t: 0, pose: [:])]).validate())
        XCTAssertThrowsError(try Clip(id: "x", keys: []).validate())
        XCTAssertThrowsError(try Clip(id: "x", keys: [ClipKey(t: 1, pose: [:]), ClipKey(t: 0, pose: [:])]).validate())
        XCTAssertThrowsError(try Clip(id: "x", keys: [ClipKey(t: 0, pose: ["tail": 3])]).validate()) { e in
            XCTAssertEqual(e as? Clip.ValidationError, .unknownChannel(clip: "x", channel: "tail"))
        }
        XCTAssertNoThrow(try clip.validate())
    }

    func testDecodeFormatFromDocs() throws {
        let json = #"{"id":"wave","fps":12,"loop":false,"keys":[{"t":0,"ease":"out","pose":{"armR.upper":-20}}],"dot":{"mode":"pulse","speed":1.5}}"#
        let c = try ClipLibrary.decode(Data(json.utf8))
        XCTAssertEqual(c.keys.first?.ease, .out)
    }
}

final class ProceduralTests: XCTestCase {
    func testTwoBoneIKReachesTarget() {
        let root = Vec2(0, 18), l1 = 9.0, l2 = 9.0
        for target in [Vec2(3, 2), Vec2(-5, 4), Vec2(8, 12), Vec2(0, 1)] {
            for bend in [1.0, -1.0] {
                let (u, l) = TwoBoneIK.solve(root: root, target: target, upper: l1, lower: l2, bend: bend)
                let mid = root + ForwardKinematics.limbDirection(u) * l1
                let end = mid + ForwardKinematics.limbDirection(u + l) * l2
                XCTAssertEqual(end.x, target.x, accuracy: 1e-6, "\(target) \(bend)")
                XCTAssertEqual(end.y, target.y, accuracy: 1e-6, "\(target) \(bend)")
            }
        }
    }

    func testIKStretchesWhenOutOfReach() {
        let (u, l) = TwoBoneIK.solve(root: .zero, target: Vec2(100, 0), upper: 9, lower: 9)
        XCTAssertEqual(u, 90, accuracy: 0.1)
        XCTAssertEqual(l, 0, accuracy: 0.5)
    }

    func testSquashSpringSettles() {
        var s = SquashSpring()
        s.kick(-3)
        var minV = 1.0, maxV = 1.0
        for _ in 0..<120 { s.step(1.0 / 60); minV = min(minV, s.value); maxV = max(maxV, s.value) }
        XCTAssertLessThan(minV, 0.95, "amassa")
        XCTAssertGreaterThan(maxV, 1.0, "overshoot")
        XCTAssertEqual(s.value, 1, accuracy: 0.01, "volta ao neutro")
    }

    func testDotModes() {
        let a = DotAnimator(), head = Vec2(0, 38)
        XCTAssertEqual(a.draw(mode: .steady, time: 0, since: 0, head: head).particles, [])
        XCTAssertEqual(a.draw(mode: .orbit, time: 1, since: 1, head: head, planned: 16).particles.count, 4, "log2(16)")
        XCTAssertEqual(a.draw(mode: .trail, time: 1, since: 1, head: head, target: Vec2(200, 0)).particles.count, 4)
        XCTAssertTrue(a.draw(mode: .alert, time: 0, since: 0, head: head).alert)
        let fade = a.draw(mode: .fade, time: 0, since: 0, head: head)
        XCTAssertTrue(fade.sleeping)
        XCTAssertLessThan(fade.opacity, 0.5)
        XCTAssertLessThan(a.draw(mode: .shrink, time: 0, since: 0, head: head).radius, SkeletonMetrics().dotRadius)
        // Pisca 2× e para.
        XCTAssertLessThan(a.draw(mode: .blink, time: 0, since: 0.3, head: head).opacity, 0.5)
        XCTAssertEqual(a.draw(mode: .blink, time: 0, since: 2, head: head).opacity, 1)
    }

    func testLookAngleIsLimited() {
        XCTAssertLessThanOrEqual(abs(Procedural.lookAngle(toward: Vec2(1, 1000), facing: 1)), 25)
        XCTAssertEqual(Procedural.lookAngle(toward: .zero, facing: 1), 0)
    }
}
