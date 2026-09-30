import Foundation

public enum GlyphProtocol {
    /// Versão do protocolo falada por este build.
    public static let version = 0
    /// Linha máxima aceita no socket (bytes). Protege contra pares que nunca mandam `\n`.
    public static let maxLineBytes = 1 << 20
}

/// Todas as mensagens do Glyph Protocol v0.
public enum Message: Sendable, Equatable {
    case hello(Hello)
    case worldUpdate(WorldUpdate)
    case inputSummon(InputSummon)
    case inputBrake(InputBrake)
    case approvalResponse(ApprovalResponse)
    case bodyGoto(BodyGoto)
    case bodyEmote(BodyEmote)
    case bubbleSay(BubbleSay)
    case approvalRequest(ApprovalRequest)
    case taskUpdate(TaskUpdate)
    case agentSpawn(AgentSpawn)
    case agentDespawn(AgentDespawn)
    case diaryReady(DiaryReady)
    case taskShelf(TaskShelf)
    case inputDrop(InputDrop)
    case offerActions(OfferActions)
    case offerChoice(OfferChoice)

    public enum Kind: String, Sendable, CaseIterable {
        case hello
        case worldUpdate = "world.update"
        case inputSummon = "input.summon"
        case inputBrake = "input.brake"
        case approvalResponse = "approval.response"
        case bodyGoto = "body.goto"
        case bodyEmote = "body.emote"
        case bubbleSay = "bubble.say"
        case approvalRequest = "approval.request"
        case taskUpdate = "task.update"
        case agentSpawn = "agent.spawn"
        case agentDespawn = "agent.despawn"
        case diaryReady = "diary.ready"
        case taskShelf = "task.shelf"
        case inputDrop = "input.drop"
        case offerActions = "offer.actions"
        case offerChoice = "offer.choice"

        /// Quem pode enviar este tipo. `approval.request` só vem do cérebro;
        /// `approval.response` só vem do corpo (app assinado).
        public var allowedSenders: Set<Peer> {
            switch self {
            case .hello: return [.body, .brain]
            case .worldUpdate, .inputSummon, .inputBrake, .approvalResponse,
                 .taskShelf, .inputDrop, .offerChoice: return [.body]
            case .bodyGoto, .bodyEmote, .bubbleSay, .approvalRequest,
                 .taskUpdate, .agentSpawn, .agentDespawn, .diaryReady, .offerActions: return [.brain]
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .hello: return .hello
        case .worldUpdate: return .worldUpdate
        case .inputSummon: return .inputSummon
        case .inputBrake: return .inputBrake
        case .approvalResponse: return .approvalResponse
        case .bodyGoto: return .bodyGoto
        case .bodyEmote: return .bodyEmote
        case .bubbleSay: return .bubbleSay
        case .approvalRequest: return .approvalRequest
        case .taskUpdate: return .taskUpdate
        case .agentSpawn: return .agentSpawn
        case .agentDespawn: return .agentDespawn
        case .diaryReady: return .diaryReady
        case .taskShelf: return .taskShelf
        case .inputDrop: return .inputDrop
        case .offerActions: return .offerActions
        case .offerChoice: return .offerChoice
        }
    }

    var payload: any Encodable & Sendable {
        switch self {
        case let .hello(p): return p
        case let .worldUpdate(p): return p
        case let .inputSummon(p): return p
        case let .inputBrake(p): return p
        case let .approvalResponse(p): return p
        case let .bodyGoto(p): return p
        case let .bodyEmote(p): return p
        case let .bubbleSay(p): return p
        case let .approvalRequest(p): return p
        case let .taskUpdate(p): return p
        case let .agentSpawn(p): return p
        case let .agentDespawn(p): return p
        case let .diaryReady(p): return p
        case let .taskShelf(p): return p
        case let .inputDrop(p): return p
        case let .offerActions(p): return p
        case let .offerChoice(p): return p
        }
    }
}

/// Envelope comum. No fio, os campos do conteúdo ficam no mesmo nível de
/// `v`, `id`, `type` e `ts` (JSON plano, uma mensagem por linha).
public struct Envelope: Sendable, Equatable {
    public var v: Int
    public var id: String
    public var ts: Date
    public var message: Message

    public var type: String { message.kind.rawValue }

    public init(v: Int = GlyphProtocol.version, id: String, ts: Date = Date(), message: Message) {
        self.v = v
        self.id = id
        self.ts = ts
        self.message = message
    }
}

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case unknownType(String)
    case unsupportedVersion(Int)
    case notAllowed(type: String, sender: Peer)
    case lineTooLong(Int)
    case invalid(String)

    public var description: String {
        switch self {
        case let .unknownType(t): return "tipo de mensagem desconhecido: \(t)"
        case let .unsupportedVersion(v): return "versão de protocolo não suportada: \(v)"
        case let .notAllowed(t, s): return "\(t) não é aceito vindo de \(s.rawValue)"
        case let .lineTooLong(n): return "linha com \(n) bytes excede o limite"
        case let .invalid(why): return "mensagem inválida: \(why)"
        }
    }
}

extension Envelope: Codable {
    enum CodingKeys: String, CodingKey { case v, id, type, ts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(Date.self, forKey: .ts)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Message.Kind(rawValue: type) else { throw ProtocolError.unknownType(type) }
        switch kind {
        case .hello: message = .hello(try Hello(from: decoder))
        case .worldUpdate: message = .worldUpdate(try WorldUpdate(from: decoder))
        case .inputSummon: message = .inputSummon(try InputSummon(from: decoder))
        case .inputBrake: message = .inputBrake(try InputBrake(from: decoder))
        case .approvalResponse: message = .approvalResponse(try ApprovalResponse(from: decoder))
        case .bodyGoto: message = .bodyGoto(try BodyGoto(from: decoder))
        case .bodyEmote: message = .bodyEmote(try BodyEmote(from: decoder))
        case .bubbleSay: message = .bubbleSay(try BubbleSay(from: decoder))
        case .approvalRequest: message = .approvalRequest(try ApprovalRequest(from: decoder))
        case .taskUpdate: message = .taskUpdate(try TaskUpdate(from: decoder))
        case .agentSpawn: message = .agentSpawn(try AgentSpawn(from: decoder))
        case .agentDespawn: message = .agentDespawn(try AgentDespawn(from: decoder))
        case .diaryReady: message = .diaryReady(try DiaryReady(from: decoder))
        case .taskShelf: message = .taskShelf(try TaskShelf(from: decoder))
        case .inputDrop: message = .inputDrop(try InputDrop(from: decoder))
        case .offerActions: message = .offerActions(try OfferActions(from: decoder))
        case .offerChoice: message = .offerChoice(try OfferChoice(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(ts, forKey: .ts)
        try message.payload.encode(to: encoder)
    }
}
