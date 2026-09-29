import Foundation
import GlyphCore

/// Emite o roteiro do `MockBrain` como JSON por linha.
/// Usado por `glyphd mock` para inspecionar o protocolo sem o corpo.
public struct MockStream: Sendable {
    public var speed: Double
    public var loops: Bool

    public init(speed: Double = 1, loops: Bool = false) {
        self.speed = speed
        self.loops = loops
    }

    /// Todas as linhas de uma volta do roteiro, sem esperar (`speed` infinito).
    public func allLines(now: Date = Date()) throws -> [String] {
        var brain = MockBrain(loops: false)
        let codec = LineCodec()
        return try brain.poll(elapsed: .greatestFiniteMagnitude, now: now).map { try codec.encodeString($0) }
    }

    /// Escreve as linhas no tempo do roteiro.
    public func run(write: (String) -> Void) throws {
        var brain = MockBrain(loops: loops)
        let codec = LineCodec()
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start) * speed
            for env in brain.poll(elapsed: elapsed) { write(try codec.encodeString(env)) }
            if !loops, elapsed > brain.period { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
