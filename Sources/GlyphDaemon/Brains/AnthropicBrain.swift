import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude pela Messages API (HTTP direto: não há SDK oficial em Swift).
///
/// - Modelo padrão: `claude-opus-5-5`.
/// - Esforço (`output_config.effort`) configurável; o padrão do modelo é `medium`.
/// - Fallback de recusa ligado por padrão (`fallbacks: "default"`): se os
///   classificadores recusarem, a API tenta de novo num modelo de reserva na
///   mesma chamada. Desligue com `fallbacks: false` na configuração.
/// - O conteúdo do assistente é reenviado exatamente como veio (blocos de
///   pensamento inclusive): a conversa é só acrescentada, nunca editada.
public struct AnthropicBrain: Brain {
    public static let defaultModel = "claude-opus-5-5"
    public static let apiVersion = "2023-06-01"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var model: String
    public var apiKey: String
    public var effort: String?
    public var maxTokens: Int
    public var fallbacks: Bool
    public var baseURL: URL
    public var transport: HTTPTransport

    public init(apiKey: String, model: String = AnthropicBrain.defaultModel, effort: String? = "medium",
                maxTokens: Int = 16000, fallbacks: Bool = true,
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.fallbacks = fallbacks
        self.baseURL = baseURL
        self.transport = transport
    }

    public var id: String { "anthropic:\(model)" }

    public func requestBody(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "system": .string(system),
            "messages": .array(Self.messages(turns)),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { t in
                .object(["name": .string(t.name), "description": .string(t.description), "input_schema": t.inputSchema])
            })
        }
        if let effort { body["output_config"] = .object(["effort": .string(effort)]) }
        if fallbacks { body["fallbacks"] = .string("default") }
        return .object(body)
    }

    static func messages(_ turns: [ChatTurn]) -> [JSONValue] {
        turns.map { turn in
            switch turn {
            case let .user(text):
                return .object(["role": .string("user"), "content": .string(text)])
            case let .assistant(text, calls, raw):
                if let raw { return .object(["role": .string("assistant"), "content": raw]) }
                var blocks: [JSONValue] = []
                if !text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
                for c in calls {
                    blocks.append(.object(["type": .string("tool_use"), "id": .string(c.id),
                                           "name": .string(c.name), "input": c.input]))
                }
                return .object(["role": .string("assistant"), "content": .array(blocks)])
            case let .toolResults(results):
                // Todos os resultados numa única mensagem de usuário.
                return .object(["role": .string("user"), "content": .array(results.map { r in
                    .object(["type": .string("tool_result"), "tool_use_id": .string(r.callID),
                             "content": .string(r.content), "is_error": .bool(r.isError)])
                })])
            }
        }
    }

    public static func parse(_ json: JSONValue) throws -> BrainReply {
        guard case let .array(blocks)? = json["content"] else { throw BrainError.badResponse("sem content") }
        var text = ""
        var calls: [ToolCall] = []
        for b in blocks {
            switch b["type"]?.stringValue {
            case "text":
                text += b["text"]?.stringValue ?? ""
            case "tool_use":
                guard let id = b["id"]?.stringValue, let name = b["name"]?.stringValue else { continue }
                calls.append(ToolCall(id: id, name: name, input: b["input"] ?? .object([:])))
            default:
                break // thinking, fallback e outros: ficam só no `raw`
            }
        }
        let stop: StopReason
        switch json["stop_reason"]?.stringValue {
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "pause_turn": stop = .pause
        case "refusal": stop = .refusal(json["stop_details"]?["category"]?.stringValue)
        default: stop = .done
        }
        let usage = Usage(inputTokens: Int(json["usage"]?["input_tokens"]?.numberValue ?? 0),
                          outputTokens: Int(json["usage"]?["output_tokens"]?.numberValue ?? 0))
        return BrainReply(text: text, toolCalls: stop == .toolUse ? calls : calls, stop: stop,
                          raw: .array(blocks), usage: usage, model: json["model"]?.stringValue)
    }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        guard !apiKey.isEmpty else { throw BrainError.missingKey("anthropic") }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if fallbacks { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try requestBody(system: system, turns: turns, tools: tools).data()
        let request = req
        let transport = self.transport
        return try await withRetries {
            let (status, data) = try await transport.send(request)
            let json = (try? JSONValue.parse(data)) ?? .null
            guard (200..<300).contains(status) else {
                throw BrainError.api(status: status, type: json["error"]?["type"]?.stringValue ?? "http",
                                     message: json["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self))
            }
            return try Self.parse(json)
        }
    }
}
