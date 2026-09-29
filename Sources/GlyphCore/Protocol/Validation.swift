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
        case let .worldUpdate(w):
            guard w.idleSeconds >= 0 else { throw ProtocolError.invalid("ociosidade negativa") }
        default:
            break
        }
    }

    /// Escolhe a maior versão comum entre dois `hello`.
    public static func negotiate(_ mine: Hello, _ theirs: Hello) -> Int? {
        Set(mine.protocolVersions).intersection(theirs.protocolVersions).max()
    }
}
