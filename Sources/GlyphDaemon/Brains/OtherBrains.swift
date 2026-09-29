import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mensagens no formato de "chat completions" (OpenAI e Ollama são parecidos).
enum ChatCompletionsFormat {
    static func messages(system: String, turns: [ChatTurn], ollama: Bool) -> [JSONValue] {
        var out: [JSONValue] = [.object(["role": .string("system"), "content": .string(system)])]
        for turn in turns {
            switch turn {
            case let .user(text):
                out.append(.object(["role": .string("user"), "content": .string(text)]))
            case let .assistant(text, calls, _):
                var m: [String: JSONValue] = ["role": .string("assistant"), "content": .string(text)]
                if !calls.isEmpty {
                    m["tool_calls"] = .array(calls.map { c in
                        if ollama {
                            return .object(["function": .object(["name": .string(c.name), "arguments": c.input])])
                        }
                        return .object(["id": .string(c.id), "type": .string("function"),
                                        "function": .object(["name": .string(c.name),
                                                             "arguments": .string(c.input.description)])])
                    })
                }
                out.append(.object(m))
            case let .toolResults(results):
                for r in results {
                    var m: [String: JSONValue] = ["role": .string("tool"), "content": .string(r.content)]
                    if ollama { m["tool_name"] = .string(r.name) } else { m["tool_call_id"] = .string(r.callID) }
                    out.append(.object(m))
                }
            }
        }
        return out
    }

    static func tools(_ tools: [ToolSpec]) -> JSONValue {
        .array(tools.map { t in
            .object(["type": .string("function"),
                     "function": .object(["name": .string(t.name), "description": .string(t.description),
                                          "parameters": t.inputSchema])])
        })
    }

    static func post(_ url: URL, headers: [String: String], body: JSONValue, transport: HTTPTransport) async throws -> JSONValue {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try body.data()
        let request = req
        return try await withRetries {
            let (status, data) = try await transport.send(request)
            let json = (try? JSONValue.parse(data)) ?? .null
            guard (200..<300).contains(status) else {
                let err = json["error"]
                throw BrainError.api(status: status,
                                     type: err?["type"]?.stringValue ?? err?["code"]?.stringValue ?? "http",
                                     message: err?["message"]?.stringValue ?? err?.stringValue
                                        ?? String(decoding: data.prefix(300), as: UTF8.self))
            }
            return json
        }
    }
}

/// Modelos da OpenAI pela API de chat completions.
public struct OpenAIBrain: Brain {
    public var model: String
    public var apiKey: String
    public var baseURL: URL
    public var transport: HTTPTransport

    public init(apiKey: String, model: String, baseURL: URL = URL(string: "https://api.openai.com")!,
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.transport = transport
    }

    public var id: String { "openai:\(model)" }

    public func requestBody(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(ChatCompletionsFormat.messages(system: system, turns: turns, ollama: false)),
        ]
        if !tools.isEmpty { body["tools"] = ChatCompletionsFormat.tools(tools) }
        return .object(body)
    }

    public static func parse(_ json: JSONValue) throws -> BrainReply {
        guard case let .array(choices)? = json["choices"], let choice = choices.first,
              let message = choice["message"] else { throw BrainError.badResponse("sem choices") }
        var calls: [ToolCall] = []
        for c in message["tool_calls"]?.arrayValue ?? [] {
            guard let id = c["id"]?.stringValue, let name = c["function"]?["name"]?.stringValue else { continue }
            let args = c["function"]?["arguments"]?.stringValue ?? "{}"
            calls.append(ToolCall(id: id, name: name, input: (try? JSONValue.parse(Data(args.utf8))) ?? .object([:])))
        }
        let stop: StopReason
        switch choice["finish_reason"]?.stringValue {
        case "tool_calls": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .refusal("content_filter")
        default: stop = calls.isEmpty ? .done : .toolUse
        }
        let usage = Usage(inputTokens: Int(json["usage"]?["prompt_tokens"]?.numberValue ?? 0),
                          outputTokens: Int(json["usage"]?["completion_tokens"]?.numberValue ?? 0))
        return BrainReply(text: message["content"]?.stringValue ?? "", toolCalls: calls, stop: stop,
                          raw: nil, usage: usage, model: json["model"]?.stringValue)
    }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        guard !apiKey.isEmpty else { throw BrainError.missingKey("openai") }
        let json = try await ChatCompletionsFormat.post(baseURL.appendingPathComponent("v1/chat/completions"),
                                                        headers: ["authorization": "Bearer \(apiKey)"],
                                                        body: requestBody(system: system, turns: turns, tools: tools),
                                                        transport: transport)
        return try Self.parse(json)
    }
}

/// Modelos locais pelo Ollama (ex.: Qwen). Privado e sem custo por token.
public struct OllamaBrain: Brain {
    public static let defaultModel = "qwen3:8b"
    public var model: String
    public var host: URL
    public var transport: HTTPTransport

    public init(model: String = OllamaBrain.defaultModel, host: URL = URL(string: "http://127.0.0.1:11434")!,
                transport: HTTPTransport = URLSessionTransport()) {
        self.model = model
        self.host = host
        self.transport = transport
    }

    public var id: String { "ollama:\(model)" }

    public func requestBody(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(false),
            "messages": .array(ChatCompletionsFormat.messages(system: system, turns: turns, ollama: true)),
        ]
        if !tools.isEmpty { body["tools"] = ChatCompletionsFormat.tools(tools) }
        return .object(body)
    }

    public static func parse(_ json: JSONValue) throws -> BrainReply {
        guard let message = json["message"] else { throw BrainError.badResponse("sem message") }
        var calls: [ToolCall] = []
        for (i, c) in (message["tool_calls"]?.arrayValue ?? []).enumerated() {
            guard let name = c["function"]?["name"]?.stringValue else { continue }
            var args = c["function"]?["arguments"] ?? .object([:])
            if case let .string(s) = args { args = (try? JSONValue.parse(Data(s.utf8))) ?? .object([:]) }
            calls.append(ToolCall(id: "ollama-\(i)-\(name)", name: name, input: args))
        }
        let stop: StopReason = !calls.isEmpty ? .toolUse : (json["done_reason"]?.stringValue == "length" ? .maxTokens : .done)
        let usage = Usage(inputTokens: Int(json["prompt_eval_count"]?.numberValue ?? 0),
                          outputTokens: Int(json["eval_count"]?.numberValue ?? 0))
        return BrainReply(text: message["content"]?.stringValue ?? "", toolCalls: calls, stop: stop,
                          raw: nil, usage: usage, model: json["model"]?.stringValue)
    }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        let json = try await ChatCompletionsFormat.post(host.appendingPathComponent("api/chat"), headers: [:],
                                                        body: requestBody(system: system, turns: turns, tools: tools),
                                                        transport: transport)
        return try Self.parse(json)
    }
}

/// Cérebro de roteiro: devolve respostas prontas. Para testes e para o modo
/// offline (`glyphd run --offline`), onde nada sai da máquina.
public final class ScriptedBrain: Brain, @unchecked Sendable {
    public typealias Script = @Sendable (_ system: String, _ turns: [ChatTurn], _ tools: [ToolSpec]) -> BrainReply
    private let lock = NSLock()
    private var calls = 0
    private let script: Script
    public let id: String

    public init(id: String = "roteiro", _ script: @escaping Script) {
        self.id = id
        self.script = script
    }

    /// Respostas em sequência; a última se repete.
    public convenience init(id: String = "roteiro", replies: [BrainReply]) {
        let box = ReplyBox(replies)
        self.init(id: id) { _, _, _ in box.next() }
    }

    public var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        count()
        return script(system, turns, tools)
    }

    private func count() {
        lock.lock(); calls += 1; lock.unlock()
    }
}

final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [BrainReply]
    init(_ r: [BrainReply]) { replies = r }
    func next() -> BrainReply {
        lock.lock(); defer { lock.unlock() }
        return replies.count > 1 ? replies.removeFirst() : (replies.first ?? BrainReply(text: "hm."))
    }
}
