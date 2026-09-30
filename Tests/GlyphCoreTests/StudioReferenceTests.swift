import XCTest
@testable import GlyphCore

/// O estúdio web (docs/estudio) refaz as contas do motor em JavaScript. Este
/// teste guarda a referência do motor em docs/estudio/referencia.json; o
/// Scripts/estudio-check.mjs confere o JavaScript contra ela.
final class StudioReferenceTests: XCTestCase {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/estudio/referencia.json")

    struct Sample: Codable, Equatable {
        var clip: String
        var t: Double
        var facing: Double
        var points: [String: [Double]]
    }

    func reference() -> [Sample] {
        var out: [Sample] = []
        for id in ["wave", "walk", "jump", "climb", "ta-da", "spin", "robot"] {
            guard let clip = Packs.library[id] else { continue }
            for t in [0.0, 0.13, 0.37, 0.61, 1.05] {
                for facing in [1.0, -1.0] {
                    let sk = ForwardKinematics.solve(clip.sample(at: t), facing: facing)
                    let named: [(String, Vec2)] = [("hip", sk.hip), ("neck", sk.neck), ("headCenter", sk.headCenter),
                                                   ("handL", sk.handL), ("handR", sk.handR), ("elbowR", sk.elbowR),
                                                   ("footL", sk.footL), ("kneeR", sk.kneeR)]
                    var pts: [String: [Double]] = [:]
                    for (k, v) in named { pts[k] = [(v.x * 1000).rounded() / 1000, (v.y * 1000).rounded() / 1000] }
                    out.append(Sample(clip: id, t: t, facing: facing, points: pts))
                }
            }
        }
        return out
    }

    func testReferenceIsCurrent() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let now = try enc.encode(reference())
        if ProcessInfo.processInfo.environment["GLYPH_GRAVAR_REFERENCIA"] == "1" {
            try now.write(to: Self.url)
        }
        let saved = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: Self.url))
        XCTAssertEqual(saved, reference(),
                       "o motor mudou: rode GLYPH_GRAVAR_REFERENCIA=1 swift test --filter StudioReferenceTests e confira o estúdio")
    }
}
