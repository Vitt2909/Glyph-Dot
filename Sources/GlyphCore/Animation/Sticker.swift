import Foundation

/// Um ícone interno desenhado como adesivo (memória, tarefa, ideia…).
///
/// Nunca emoji do sistema: são traços, no mesmo estilo do Glyph. O formato é
/// JSON em `Packs/<pack>/stickers/<id>.json`, em coordenadas locais com y para
/// cima e origem no centro de uma caixa de 24×24.
public struct Sticker: Sendable, Equatable, Codable {
    public struct Circle: Sendable, Equatable, Codable {
        public var x: Double
        public var y: Double
        public var r: Double
        /// Preenchido de preto (como o Dot) em vez de só contornado.
        public var filled: Bool?

        public init(x: Double, y: Double, r: Double, filled: Bool? = nil) {
            self.x = x
            self.y = y
            self.r = r
            self.filled = filled
        }
    }

    public var id: String
    /// Polilinhas abertas: `[[x, y], [x, y], …]`.
    public var strokes: [[[Double]]]
    /// Polígonos fechados, preenchidos de branco (o papel) e contornados.
    public var shapes: [[[Double]]]?
    public var circles: [Circle]?

    public init(id: String, strokes: [[[Double]]], shapes: [[[Double]]]? = nil, circles: [Circle]? = nil) {
        self.id = id
        self.strokes = strokes
        self.shapes = shapes
        self.circles = circles
    }

    public enum ValidationError: Error, Equatable {
        case badPoint(String)
        case empty(String)
    }

    public func validate() throws {
        let all = strokes + (shapes ?? [])
        guard !all.isEmpty || !(circles ?? []).isEmpty else { throw ValidationError.empty(id) }
        for line in all where line.count < 2 || line.contains(where: { $0.count != 2 }) {
            throw ValidationError.badPoint(id)
        }
    }

    /// Geometria no estilo adesivo, com boil, posicionada em `at` e escalada.
    public func shapes(at origin: Vec2, scale: Double = 1, frame: Int = 0, seed: UInt64 = 0x5374_6B72) -> StickerShapes {
        let boil = LineBoil(seed: seed)
        var out = StickerShapes()
        var index = 0
        func pts(_ raw: [[Double]]) -> [Vec2] { raw.map { origin + Vec2($0[0], $0[1]) * scale } }
        func add(_ p: [Vec2], closed: Bool) {
            var dense = Polyline.subdivide(p, maxSegment: 4)
            dense = boil.apply(dense, baseIndex: index, frame: frame)
            index += dense.count + 11
            if closed, let f = dense.first { dense.append(f) }
            out.strokes.append(dense)
            if closed { out.fills.append(dense) }
        }
        for s in shapes ?? [] { add(pts(s), closed: true) }
        for s in strokes { add(pts(s), closed: false) }
        for c in circles ?? [] {
            let center = origin + Vec2(c.x, c.y) * scale
            if c.filled == true {
                out.discs.append(.init(center: center, radius: c.r * scale, opacity: 1))
            } else {
                add(Polyline.circle(center: center, radius: c.r * scale, segments: 16), closed: true)
            }
        }
        return out
    }

    public static func load(pack: URL) -> (stickers: [String: Sticker], errors: [String]) {
        let dir = pack.appendingPathComponent("stickers", isDirectory: true)
        var out: [String: Sticker] = [:]
        var errors: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            do {
                let s = try JSONDecoder().decode(Sticker.self, from: Data(contentsOf: url))
                try s.validate()
                guard s.id == url.deletingPathExtension().lastPathComponent else {
                    errors.append("\(url.lastPathComponent): id diferente do nome do arquivo")
                    continue
                }
                out[s.id] = s
            } catch {
                errors.append("\(url.lastPathComponent): \(error)")
            }
        }
        return (out, errors)
    }
}
