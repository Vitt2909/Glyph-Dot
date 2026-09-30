import Foundation

// Objetos que representam tarefas (proposta 0002, ideia 3) e ofertas de ação
// ao redor de um objeto entregue (ideia 1).
//
// A regra: a animação comunica trabalho real. Um objeto só aparece quando o
// cérebro mandou uma tarefa (`task.update` com `object`) ou uma oferta.

/// Uma tarefa que o Glyph carrega.
public struct TaskObject: Sendable, Equatable {
    public var id: String
    public var object: String
    public var title: String
    public var step: String
    public var progress: Double
    public var state: TaskUpdate.State
    public var pending: String?
    public var result: String?
    public var updated: Double
    /// Arquivo que o clique abre.
    public var open: String? = nil

    /// Uma linha para a bolha, ao clicar no objeto.
    public var line: String {
        let name = title.isEmpty ? id : title
        switch state {
        case .doing:
            let pct = Int((progress * 100).rounded())
            return "\(name): \(step)" + (progress > 0 ? " (\(pct)%)" : "")
        case .needsYou:
            return "\(name): precisa de você" + (pending.map { " — \($0)" } ?? "")
        case .done:
            return "\(name): pronto" + (result.map { ". \($0)" } ?? ".")
        case .failed:
            return "\(name): não deu" + (result.map { ". \($0)" } ?? ".")
        case .parked:
            return "\(name): na prateleira."
        }
    }

    /// Continua na mão até você ver o resultado (clique).
    public var isCarried: Bool { state != .parked }
    /// Some depois do clique.
    public var isFinished: Bool { state == .done || state == .failed }
}

/// Uma oferta em aberto: o objeto na mão e as ações ao redor.
public struct Offer: Sendable, Equatable {
    public var id: String
    public var object: String
    public var title: String
    public var actions: [OfferAction]
    public var until: Double
}

/// Um sticker desenhado fora da mão (ações ao redor do objeto).
public struct Prop: Sendable, Equatable {
    public var sticker: Sticker
    /// Centro, em coordenadas globais.
    public var center: Vec2
    public var scale: Double

    public init(sticker: Sticker, center: Vec2, scale: Double = 0.9) {
        self.sticker = sticker
        self.center = center
        self.scale = scale
    }

    /// Raio aproximado para clique.
    public var hitRadius: Double { 13 * scale / 0.9 }
}
