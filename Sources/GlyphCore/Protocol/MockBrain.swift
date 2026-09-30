import Foundation

/// Cérebro falso para `GLYPH_MOCK=1`: um roteiro determinístico de mensagens
/// do cérebro para o corpo, e respostas simples ao que o corpo manda.
///
/// Serve para desenvolver o corpo sem `glyphd` e sem nenhum modelo.
public struct MockBrain: Sendable {
    public struct Step: Sendable, Equatable {
        /// Segundos desde o início do roteiro.
        public var at: Double
        public var message: Message

        public init(at: Double, _ message: Message) {
            self.at = at
            self.message = message
        }
    }

    public let script: [Step]
    public let loops: Bool
    private var cursor = 0
    private var loopOffset = 0.0
    private var counter = 0

    public init(script: [Step] = MockBrain.defaultScript, loops: Bool = true) {
        precondition(zip(script, script.dropFirst()).allSatisfy { $0.at <= $1.at }, "roteiro fora de ordem")
        self.script = script
        self.loops = loops
    }

    /// Duração de uma volta do roteiro.
    public var period: Double { (script.last?.at ?? 0) + 5 }

    /// Devolve as mensagens cujo horário já passou, em ordem.
    public mutating func poll(elapsed: Double, now: Date = Date()) -> [Envelope] {
        var out: [Envelope] = []
        while !script.isEmpty {
            if cursor == script.count {
                guard loops, elapsed >= loopOffset + period else { break }
                cursor = 0
                loopOffset += period
            }
            let step = script[cursor]
            guard elapsed >= step.at + loopOffset else { break }
            out.append(envelope(step.message, now: now))
            cursor += 1
        }
        return out
    }

    /// Resposta imediata a uma mensagem do corpo.
    public mutating func respond(to envelope: Envelope, now: Date = Date()) -> [Envelope] {
        switch envelope.message {
        case .hello:
            return [self.envelope(.hello(Hello(role: .brain, capabilities: ["mock"], name: "mock")), now: now)]
        case let .inputSummon(s):
            let text = s.text.map { $0.isEmpty ? "oi." : "(mock) ouvi." } ?? "oi."
            return [self.envelope(.bodyEmote(BodyEmote(clip: "wave", dot: .pulse)), now: now),
                    self.envelope(.bubbleSay(BubbleSay(text: text)), now: now)]
        case let .approvalResponse(r):
            let text: String
            switch r.decision {
            case .approve: text = "ok, feito."
            case .deny: text = "tudo bem, deixo quieto."
            case .always: text = "anotado."
            }
            return [self.envelope(.bubbleSay(BubbleSay(text: text)), now: now)]
        case let .inputDrop(d):
            // Entrega de mentira: segura o objeto e oferece ações.
            let name = (d.paths.first.map { ($0 as NSString).lastPathComponent }) ?? "arquivo"
            return [self.envelope(.offerActions(OfferActions(offerId: "mock-oferta", object: "folha", title: name, actions: [
                OfferAction(id: "resumir", label: "resumir", sticker: "folha"),
                OfferAction(id: "tarefas", label: "tarefas", sticker: "alfinete"),
            ])), now: now)]
        case let .offerChoice(c):
            guard let a = c.actionId else { return [] }
            return [self.envelope(.taskUpdate(TaskUpdate(taskId: c.offerId, step: a, progress: 1, object: "envelope",
                                                         title: "(mock) \(a)", state: .done, result: "feito de mentira.")), now: now)]
        default:
            return []
        }
    }

    private mutating func envelope(_ m: Message, now: Date) -> Envelope {
        counter += 1
        return Envelope(id: "mock-\(counter)", ts: now, message: m)
    }

    /// Roteiro padrão: passa pelos estados principais do Dot.
    public static let defaultScript: [Step] = [
        Step(at: 1, .hello(Hello(role: .brain, capabilities: ["mock"], name: "mock"))),
        Step(at: 2, .bodyEmote(BodyEmote(clip: "idle", dot: .steady))),
        Step(at: 6, .bubbleSay(BubbleSay(text: "oi. sou o Glyph."))),
        Step(at: 10, .bodyEmote(BodyEmote(clip: "think", dot: .orbit))),
        Step(at: 14, .taskUpdate(TaskUpdate(taskId: "mock-task", step: "rodando testes", progress: 0.3, budgetRemaining: 3))),
        Step(at: 15, .bodyEmote(BodyEmote(clip: "walk", dot: .trail))),
        Step(at: 20, .taskUpdate(TaskUpdate(taskId: "mock-task", step: "testes rodados", progress: 1, budgetRemaining: 2))),
        Step(at: 21, .bubbleSay(BubbleSay(text: "2 testes falharam em vk/"))),
        Step(at: 24, .approvalRequest(ApprovalRequest(
            action: "git.push", target: "origin/glyph/fix-tests", actionClass: .externalEffect,
            why: "Testes voltaram a passar; abrir PR de rascunho?", timeoutSec: 20))),
        Step(at: 46, .bodyEmote(BodyEmote(clip: "error", dot: .shrink))),
        Step(at: 50, .bodyGoto(BodyGoto(target: .home))),
        Step(at: 55, .bodyEmote(BodyEmote(clip: "sleep", dot: .fade))),
    ]
}
