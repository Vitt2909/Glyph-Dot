import Foundation

// Geometria básica do Glyph.
//
// Convenção única em todo o Core: coordenadas globais do AppKit,
// origem no canto inferior esquerdo da tela principal, y cresce para cima,
// unidades em pontos. A conversão do CGWindowList (origem no topo) acontece
// só em `WorldCoordinates`.

public struct Vec2: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x / l, y / l) : .zero
    }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    /// Gira no sentido anti-horário (y para cima) por `radians`.
    public func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public static func * (k: Double, a: Vec2) -> Vec2 { Vec2(a.x * k, a.y * k) }
    public static func / (a: Vec2, k: Double) -> Vec2 { Vec2(a.x / k, a.y / k) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    public static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }
}

public struct Rect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    enum CodingKeys: String, CodingKey { case x, y, width = "w", height = "h" }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Vec2 { Vec2(midX, midY) }
    public var origin: Vec2 { Vec2(x, y) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Contém o ponto, bordas incluídas.
    public func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func contains(_ r: Rect) -> Bool {
        r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func intersects(_ r: Rect) -> Bool {
        minX < r.maxX && r.minX < maxX && minY < r.maxY && r.minY < maxY
    }

    public func intersection(_ r: Rect) -> Rect? {
        let nx0 = Swift.max(minX, r.minX), ny0 = Swift.max(minY, r.minY)
        let nx1 = Swift.min(maxX, r.maxX), ny1 = Swift.min(maxY, r.maxY)
        guard nx1 > nx0, ny1 > ny0 else { return nil }
        return Rect(minX: nx0, minY: ny0, maxX: nx1, maxY: ny1)
    }

    public func union(_ r: Rect) -> Rect {
        Rect(minX: Swift.min(minX, r.minX), minY: Swift.min(minY, r.minY),
             maxX: Swift.max(maxX, r.maxX), maxY: Swift.max(maxY, r.maxY))
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    public func offsetBy(_ d: Vec2) -> Rect {
        Rect(x: x + d.x, y: y + d.y, width: width, height: height)
    }
}

extension Double {
    /// Restringe ao intervalo fechado.
    public func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }

    public static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    public var radians: Double { self * .pi / 180 }
    public var degrees: Double { self * 180 / .pi }
}
