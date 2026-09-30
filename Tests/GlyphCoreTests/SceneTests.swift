import XCTest
@testable import GlyphCore

final class SceneTests: XCTestCase {
    static let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Examples/pack-exemplo", isDirectory: true)

    func testExamplePackScenesLoad() {
        let p = PackLoader.loadPack(Self.example, requireManifest: true)
        XCTAssertTrue(p.errors.isEmpty, "\(p.errors)")
        XCTAssertEqual(Set(p.scenes.map(\.event)), [.testsPassed, .auditorVeto])
        let all = PackLoader.scenes(default: Packs.defaultPack, community: [Self.example])
        XCTAssertEqual(all[.auditorVeto]?.id, "veto-conversa")
    }

    func testSafetySignalsCannotBeStaged() {
        func check(_ beat: SceneBeat) -> Bool {
            (try? Scene(id: "x", event: .auditorVeto, beats: [beat]).validate()) != nil
        }
        XCTAssertTrue(check(SceneBeat(actor: "glyph", at: 0, clip: "wave")))
        XCTAssertFalse(check(SceneBeat(actor: "glyph", at: 0, clip: "await")), "esperando aprovação é sinal de verdade")
        XCTAssertFalse(check(SceneBeat(actor: "glyph", at: 0, clip: "wave", sticker: "cartao")))
        XCTAssertFalse(check(SceneBeat(actor: "vilao", at: 0, clip: "wave")))
        XCTAssertFalse(check(SceneBeat(actor: "glyph", at: 25, clip: "wave")))
        XCTAssertFalse(check(SceneBeat(actor: "glyph", at: 0, clip: "wave", bubble: String(repeating: "a", count: 41))))
        XCTAssertThrowsError(try Scene.decode(Data(#"{"id":"x","event":"inventado","beats":[]}"#.utf8)), "evento só dos reais")
    }

    func engine() -> GlyphEngine {
        var e = GlyphEngine(world: WorldSnapshot(screens: [TestWorlds.screen]), clips: Packs.library,
                            stickers: TaskObjectTests.stickers, start: Vec2(700, 200))
        e.scenes = [.testsPassed: Scene(id: "festa", event: .testsPassed, beats: [
            SceneBeat(actor: "glyph", at: 0, clip: "ta-da", bubble: "passou!"),
            SceneBeat(actor: "auditor", at: 0.5, clip: "wave", bubble: "ok."),
        ])]
        for _ in 0..<60 { e.advance(by: 1.0 / 60); _ = e.drawing }
        return e
    }

    func testSceneOnlyPlaysOnARealEvent() {
        var e = engine()
        for _ in 0..<60 { e.advance(by: 1.0 / 60) }
        XCTAssertNil(e.drawing?.bubble, "sem evento, sem cena")
        e.receive(.sceneCue(SceneCue(event: .auditorVeto)))
        e.advance(by: 0.1)
        XCTAssertNil(e.drawing?.bubble, "evento sem cena no pack: nada")
        e.receive(.sceneCue(SceneCue(event: .testsPassed)))
        e.advance(by: 0.1)
        XCTAssertEqual(e.drawing?.bubble, "passou!")
    }

    func testSpecialistActsOnlyIfReallyThere() {
        var e = engine()
        e.receive(.sceneCue(SceneCue(event: .testsPassed)))
        for _ in 0..<60 { e.advance(by: 1.0 / 60) }
        XCTAssertTrue(e.companions.isEmpty, "a cena não inventa o Auditor")

        var f = engine()
        f.receive(.agentSpawn(AgentSpawn(agentId: "a1", role: .auditor)))
        for _ in 0..<60 { f.advance(by: 1.0 / 60) }
        f.receive(.sceneCue(SceneCue(event: .testsPassed)))
        for _ in 0..<60 { f.advance(by: 1.0 / 60) }
        XCTAssertEqual(f.companions.first?.bubble, "ok.")
        XCTAssertEqual(f.companions.first?.clip, "wave")
    }

    func testNeverOverAnApproval() {
        var e = engine()
        e.receive(.approvalRequest(ApprovalRequest(action: "git.push", target: "x", actionClass: .externalEffect, why: "publicar?")))
        e.receive(.sceneCue(SceneCue(event: .testsPassed)))
        e.advance(by: 0.2)
        XCTAssertEqual(e.drawing?.bubble, "publicar?")
    }
}
