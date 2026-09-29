import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// JSON genérico, para esquemas de ferramentas e entradas de chamadas.
public indirect enum JSONValue: Sendable, Equatable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(d):
            if d == d.rounded(), abs(d) < 1e15 { try c.encode(Int(d)) } else { try c.encode(d) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var numberValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func data() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public var description: String {
        (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
}

/// Descrição de uma ferramenta para o modelo.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema da entrada.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResult: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var content: String
    public var isError: Bool

    public init(callID: String, name: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }
}

/// Um turno da conversa, independente de provedor.
public enum ChatTurn: Sendable, Equatable {
    case user(String)
    /// `raw`: o conteúdo exato devolvido pelo provedor, reenviado sem mudanças
    /// (a Anthropic exige os blocos de pensamento intactos).
    case assistant(text: String, toolCalls: [ToolCall], raw: JSONValue?)
    case toolResults([ToolResult])
}

public enum StopReason: Sendable, Equatable {
    case done
    case toolUse
    case maxTokens
    /// O modelo recusou (classificadores de segurança). Categoria, se houver.
    case refusal(String?)
    /// A API pausou um turno longo; basta continuar.
    case pause
}

public struct Usage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }

    public var total: Int { inputTokens + outputTokens }
}

public struct BrainReply: Sendable, Equatable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var stop: StopReason
    public var raw: JSONValue?
    public var usage: Usage
    /// Modelo que de fato respondeu (pode ser um fallback).
    public var model: String?

    public init(text: String, toolCalls: [ToolCall] = [], stop: StopReason = .done, raw: JSONValue? = nil,
                usage: Usage = Usage(), model: String? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.stop = stop
        self.raw = raw
        self.usage = usage
        self.model = model
    }

    public var assistantTurn: ChatTurn { .assistant(text: text, toolCalls: toolCalls, raw: raw) }
}

public enum BrainError: Error, Equatable, CustomStringConvertible {
    case missingKey(String)
    case api(status: Int, type: String, message: String)
    case transport(String)
    case badResponse(String)

    public var retryable: Bool {
        switch self {
        case let .api(status, _, _): return status == 408 || status == 409 || status == 429 || status >= 500
        case .transport: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case let .missingKey(p): return "sem chave de API para \(p) (Keychain ou variável de ambiente)"
        case let .api(s, t, m): return "API \(s) \(t): \(m)"
        case let .transport(m): return "rede: \(m)"
        case let .badResponse(m): return "resposta inesperada: \(m)"
        }
    }
}

/// Um cérebro: recebe a conversa e as ferramentas, devolve texto e/ou chamadas.
///
/// O plano pede três operações (`plan`, `act`, `summarize`); aqui elas são
/// prompts diferentes sobre o mesmo `respond` (veja `AgentLoop`).
public protocol Brain: Sendable {
    /// Ex.: "anthropic:claude-opus-5-5".
    var id: String { get }
    func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply
}

// MARK: - HTTP

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: BrainError.transport(error.localizedDescription))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                cont.resume(returning: (status, data ?? Data()))
            }
            task.resume()
        }
    }
}

/// Repete pedidos que falharam por motivo passageiro (429, 5xx, rede).
func withRetries<T: Sendable>(_ attempts: Int = 3, _ op: @Sendable () async throws -> T) async throws -> T {
    var delay: UInt64 = 800_000_000
    for i in 0..<attempts {
        do {
            return try await op()
        } catch let e as BrainError where e.retryable && i < attempts - 1 {
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
    }
    return try await op()
}
