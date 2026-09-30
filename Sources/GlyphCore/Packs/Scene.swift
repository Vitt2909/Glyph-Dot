import Foundation

// Cenas entre especialistas (proposta 0002, ideia 7).
//
// Uma cena é só encenação: quem entra, quando, com que clipe, bolha e
// sticker. Ela toca ligada a um evento de verdade que o `glyphd` manda
// (`scene.cue`). O pack fornece a cena; nunca o evento. Uma cena de "veto"
// sem veto de verdade enganaria sobre o que aconteceu.

/// Eventos reais que uma cena pode encenar.
public enum SceneEvent: String, Sendable, Codable, CaseIterable {
    /// O Auditor vetou o trabalho do Builder.
    case auditorVeto = "auditor.veto"
    /// O Auditor aprovou.
    case auditorApproved = "auditor.aprovou"
    /// Os testes voltaram a passar.
    case testsPassed = "teste.passou"
    /// Terminou algo que você entregou (resumo, mapa…).
    case deliveryDone = "entrega.pronta"
    /// Você aprovou uma rotina ensinada.
    case routineApproved = "rotina.aprovada"
}

public struct SceneBeat: Sendable, Equatable, Codable {
    /// `glyph` (o principal) ou um papel: builder, researcher, designer, auditor.
    public var actor: String
    /// Segundos desde o começo da cena.
    public var at: Double
    public var clip: String
    public var bubble: String?
    public var sticker: String?

    public init(actor: String, at: Double, clip: String, bubble: String? = nil, sticker: String? = nil) {
        self.actor = actor
        self.at = at
        self.clip = clip
        self.bubble = bubble
        self.sticker = sticker
    }
}

public struct Scene: Sendable, Equatable, Codable {
    public var id: String
    public var event: SceneEvent
    public var beats: [SceneBeat]

    public init(id: String, event: SceneEvent, beats: [SceneBeat]) {
        self.id = id
        self.event = event
        self.beats = beats
    }

    public static let maxBeats = 24
    public static let maxLength = 20.0
    public static let actors: Set<String> = Set(["glyph"] + SpecialistRole.allCases.map(\.rawValue))

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String { if case let .invalid(m) = self { return m }; return "" }
    }

    public func validate() throws {
        func bad(_ m: String) -> ValidationError { .invalid("\(id): \(m)") }
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ ($0.isLowercase || $0.isNumber || $0 == "-") && $0.isASCII }) else {
            throw ValidationError.invalid("id inválido: \(id)")
        }
        guard !beats.isEmpty, beats.count <= Self.maxBeats else { throw bad("entre 1 e \(Self.maxBeats) batidas") }
        for b in beats {
            guard Self.actors.contains(b.actor) else { throw bad("ator desconhecido \(b.actor)") }
            guard b.at >= 0, b.at <= Self.maxLength else { throw bad("batida fora de 0…\(Int(Self.maxLength)) s") }
            // Sinais de segurança não entram em cena: eles significam algo de verdade.
            guard !PackLoader.protectedClips.contains(b.clip) else { throw bad("o clipe \(b.clip) é sinal de segurança") }
            if let s = b.sticker, PackLoader.protectedStickers.contains(s) { throw bad("o sticker \(s) é sinal de segurança") }
            if let t = b.bubble, t.count > BubbleSay.maxLength { throw bad("bolha com mais de \(BubbleSay.maxLength) caracteres") }
        }
    }

    public static func decode(_ data: Data) throws -> Scene {
        let s = try JSONDecoder().decode(Scene.self, from: data)
        try s.validate()
        return s
    }
}
