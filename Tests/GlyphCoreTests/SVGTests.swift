import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import GlyphCore

final class SVGTests: XCTestCase {
    func isWellFormedXML(_ s: String) -> Bool {
        let p = XMLParser(data: Data(s.utf8))
        return p.parse()
    }

    func testStaticFrameIsValidSVG() {
        var d = GlyphDrawing.standing(at: Vec2(60, 20))
        d.bubble = "oi <você> & eu"
        let svg = SVGRenderer.render(d, SVGRenderer.Canvas(width: 120, height: 100), background: "#fff", title: "t")
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(isWellFormedXML(svg), svg)
        XCTAssertTrue(svg.contains("&lt;você>"), "texto da bolha escapado")
        XCTAssertTrue(svg.contains(#"stroke-width="2.5""#), "traço preto de 2,5 pt")
        XCTAssertTrue(svg.contains(#"stroke-width="8.5""#), "contorno branco de 3 pt por lado")
    }

    func testCoordinatesFlipY() {
        let c = SVGRenderer.Canvas(origin: Vec2(10, 0), width: 100, height: 50, scale: 2)
        let (x, y) = c.map(Vec2(10, 0))
        XCTAssertEqual(x, 0)
        XCTAssertEqual(y, 100, "o chão do mundo fica embaixo no SVG")
    }

    func testAnimationHasOneValuePerFrame() {
        let frames = (0..<5).map { i -> StickerShapes in
            var d = GlyphDrawing.standing(at: Vec2(20 + Double(i) * 5, 10))
            d.boilFrame = i * 3
            return StickerShapes.build(d)
        }
        let svg = SVGRenderer.animate(frames, fps: 12, SVGRenderer.Canvas(width: 100, height: 70))
        XCTAssertTrue(isWellFormedXML(svg))
        XCTAssertTrue(svg.contains(#"calcMode="discrete""#), "sem interpolação: animação em dois")
        let values = svg.components(separatedBy: #"values=""#)[1].components(separatedBy: "\"")[0]
        XCTAssertEqual(values.components(separatedBy: ";").count, 5)
    }

    func testDefaultStickersLoadAndRender() {
        let (stickers, errors) = Sticker.load(pack: Packs.defaultPack)
        XCTAssertEqual(errors, [])
        for id in ["folha", "alfinete", "lampada", "mochila", "casa", "cartao", "lupa", "chave", "escudo", "pincel", "relogio", "diario", "pausa"] {
            guard let s = stickers[id] else { XCTFail("falta \(id)"); continue }
            let shapes = s.shapes(at: Vec2(24, 24))
            XCTAssertFalse(shapes.strokes.isEmpty && shapes.discs.isEmpty, id)
            // Cabe na caixa de 24×24 (com folga para o boil).
            for p in shapes.strokes.flatMap({ $0 }) {
                XCTAssertLessThanOrEqual(abs(p.x - 24), 14, id)
                XCTAssertLessThanOrEqual(abs(p.y - 24), 14, id)
            }
        }
    }

    func testStickerValidation() {
        XCTAssertThrowsError(try Sticker(id: "x", strokes: []).validate())
        XCTAssertThrowsError(try Sticker(id: "x", strokes: [[[0, 0]]]).validate())
        XCTAssertNoThrow(try Sticker(id: "x", strokes: [[[0, 0], [1, 1]]]).validate())
    }

    func testNumberFormatting() {
        XCTAssertEqual(SVGRenderer.num(2), "2")
        XCTAssertEqual(SVGRenderer.num(2.04), "2")
        XCTAssertEqual(SVGRenderer.num(-1.25), "-1.3")
        XCTAssertEqual(SVGRenderer.num(0.55), "0.6")
    }
}
