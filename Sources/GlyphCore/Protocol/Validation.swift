import Foundation

/// Regras de aceitação de mensagens. Roda nos dois lados do socket.
///
/// O papel do remetente (`Peer`) vem da autenticação do socket (UID + audit
/// token), nunca de um campo da própria mensagem.
public enum ProtocolValidator {
    public static let supportedVersions: ClosedRange<Int> = 0...GlyphProtocol.version

    public static func validate(_ envelope: Envelope, from sender: Peer) throws {
        guard supportedVersions.contains(envelope.v) else {
            throw ProtocolError.unsupportedVersion(envelope.v)
        }
        guard !envelope.id.isEmpty, envelope.id.count <= 128 else {
            throw ProtocolError.invalid("id vazio ou longo demais")
        }
        let kind = envelope.message.kind
        guard kind.allowedSenders.contains(sender) else {
            throw ProtocolError.notAllowed(type: kind.rawValue, sender: sender)
        }
        try validatePayload(envelope.message, from: sender)
    }

    private static func validatePayload(_ message: Message, from sender: Peer) throws {
        switch message {
        case let .hello(h):
            guard h.role == sender else { throw ProtocolError.invalid("hello declara papel diferente do par") }
        case let .bubbleSay(b):
            guard b.durationSec > 0, b.durationSec <= 30 else { throw ProtocolError.invalid("duração de bolha fora de 0…30 s") }
        case let .approvalRequest(r):
            guard r.timeoutSec > 0, r.timeoutSec <= 3600 else { throw ProtocolError.invalid("timeout fora de 0…3600 s") }
            guard r.actionClass != .financial else { throw ProtocolError.invalid("classe financial é proibida") }
        case let .taskUpdate(t):
            guard (0...1).contains(t.progress) else { throw ProtocolError.invalid("progresso fora de 0…1") }
            if let b = t.budgetRemaining, b < 0 { throw ProtocolError.invalid("orçamento negativo") }
            if let o = t.object, !isToken(o) { throw ProtocolError.invalid("objeto inválido") }
            if let path = t.open, !path.hasPrefix("/") || path.utf8.count > 4096 { throw ProtocolError.invalid("caminho precisa ser absoluto") }
            for text in [t.title, t.pending, t.result].compactMap({ $0 }) where text.count > 500 {
                throw ProtocolError.invalid("texto da tarefa longo demais")
            }
        case let .taskShelf(t):
            guard !t.taskId.isEmpty, t.taskId.count <= 128 else { throw ProtocolError.invalid("tarefa inválida") }
        case let .inputDrop(d):
            guard !d.paths.isEmpty, d.paths.count <= InputDrop.maxPaths else { throw ProtocolError.invalid("entre 1 e \(InputDrop.maxPaths) caminhos") }
            guard d.paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
                throw ProtocolError.invalid("caminho precisa ser absoluto")
            }
        case let .offerActions(o):
            guard !o.offerId.isEmpty, o.offerId.count <= 128, isToken(o.object) else { throw ProtocolError.invalid("oferta inválida") }
            guard !o.actions.isEmpty, o.actions.count <= OfferActions.maxActions else {
                throw ProtocolError.invalid("entre 1 e \(OfferActions.maxActions) ações")
            }
            guard o.actions.allSatisfy({ isToken($0.id) && !$0.label.isEmpty && $0.label.count <= 40 && ($0.sticker.map(isToken) ?? true) }) else {
                throw ProtocolError.invalid("ação inválida")
            }
            guard o.timeoutSec > 0, o.timeoutSec <= 3600 else { throw ProtocolError.invalid("timeout fora de 0…3600 s") }
        case let .presenceHint(h):
            guard h.untilSec > 0, h.untilSec <= 3600 else { throw ProtocolError.invalid("duração fora de 0…3600 s") }
        case let .offerChoice(c):
            guard !c.offerId.isEmpty, c.offerId.count <= 128, c.actionId.map(isToken) ?? true else { throw ProtocolError.invalid("escolha inválida") }
        case let .worldUpdate(w):
            guard w.idleSeconds >= 0 else { throw ProtocolError.invalid("ociosidade negativa") }
        default:
            break
        }
    }

    /// Identificador curto: letras, números, `-` e `_`.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Escolhe a maior versão comum entre dois `hello`.
    public static func negotiate(_ mine: Hello, _ theirs: Hello) -> Int? {
        Set(mine.protocolVersions).intersection(theirs.protocolVersions).max()
    }
}
