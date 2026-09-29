import Foundation
import GlyphCore

/// Um agente externo (VK ou qualquer outro) como cérebro do Glyph.
///
/// O agente pensa; o glyphd continua sendo o único que age. O agente recebe a
/// conversa e as ferramentas e devolve texto e/ou chamadas de ferramenta, que
/// o `AgentLoop` executa pela política, como faria com qualquer provedor. O
/// agente nunca recebe as chaves do glyphd e nunca fala com o corpo por aqui.
///
/// Protocolo `glyph-brain/1` (docs/ECOSYSTEM.md): uma linha JSON por mensagem.
///
///     → {"type":"brain.request","id":"r1","protocol":"glyph-brain/1","system":"…",
///        "turns":[…],"tools":[{"name":…,"description":…,"input_schema":{…}}]}
///     ← {"type":"brain.reply","id":"r1","text":"…","tool_calls":[{"id":…,"name":…,"input":{…}}],
///        "stop":"done","usage":{"input_tokens":0,"output_tokens":0},"model":"vk-1"}
public actor ExternalAgentBrain: Brain {
    public static let protocolName = "glyph-brain/1"

    public nonisolated let id: String
    let command: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    private var proc: LineProcess?
    private var counter = 0

    public init(name: String, command: [String], environment: [String: String], timeout: TimeInterval = 300) {
        self.id = "externo:" + name
        self.command = command
        self.environment = environment
        self.timeout = timeout
    }

    public func respond(system: String, turns: [ChatTurn], tools: [ToolSpec]) async throws -> BrainReply {
        let p: LineProcess
        if let running = proc, await running.isRunning {
            p = running
        } else {
            do {
                p = try LineProcess.start(command, environment: environment)
            } catch {
                throw BrainError.transport("agente externo: \(error)")
            }
            proc = p
        }
        counter += 1
        let rid = "r\(counter)"
        let request = Self.encodeRequest(id: rid, system: system, turns: turns, tools: tools)
        do {
            try await p.send(String(decoding: try request.data(), as: UTF8.self))
        } catch {
            await drop(p)
            throw BrainError.transport("agente externo parou de ler")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let line = await p.readLine(timeout: left) else {
                let running = await p.isRunning
                await drop(p)
                throw BrainError.transport(running ? "agente externo não respondeu a tempo (\(Int(timeout.rounded(.up))) s)" : "agente externo encerrou")
            }
            guard let msg = try? JSONValue.parse(Data(line.utf8)),
                  msg["type"]?.stringValue == "brain.reply", msg["id"]?.stringValue == rid else { continue }
            return try Self.decodeReply(msg)
        }
    }

    private func drop(_ p: LineProcess) async {
        await p.stop()
        if proc === p { proc = nil }
    }

    public func stop() async {
        await proc?.stop()
        proc = nil
    }

    // MARK: - Codificação

    static func encodeRequest(id: String, system: String, turns: [ChatTurn], tools: [ToolSpec]) -> JSONValue {
        .object([
            "type": .string("brain.request"),
            "id": .string(id),
            "protocol": .string(protocolName),
            "system": .string(system),
            "turns": .array(turns.map(encodeTurn)),
            "tools": .array(tools.map { .object(["name": .string($0.name), "description": .string($0.description),
                                                 "input_schema": $0.inputSchema]) }),
        ])
    }

    static func encodeTurn(_ t: ChatTurn) -> JSONValue {
        switch t {
        case let .user(text):
            return .object(["role": .string("user"), "text": .string(text)])
        case let .assistant(text, calls, _):
            // O `raw` de outro provedor não vai para o agente: só texto e chamadas.
            return .object(["role": .string("assistant"), "text": .string(text),
                            "tool_calls": .array(calls.map { .object(["id": .string($0.id), "name": .string($0.name), "input": $0.input]) })])
        case let .toolResults(rs):
            return .object(["role": .string("tool_results"),
                            "results": .array(rs.map { .object(["call_id": .string($0.callID), "name": .string($0.name),
                                                                "content": .string($0.content), "is_error": .bool($0.isError)]) })])
        }
    }

    static func decodeReply(_ msg: JSONValue) throws -> BrainReply {
        let text = msg["text"]?.stringValue ?? ""
        var calls: [ToolCall] = []
        for (i, c) in (msg["tool_calls"]?.arrayValue ?? []).enumerated() {
            guard let name = c["name"]?.stringValue, !name.isEmpty else {
                throw BrainError.badResponse("agente externo: chamada \(i) sem nome")
            }
            let input = c["input"] ?? .object([:])
            guard case .object = input else { throw BrainError.badResponse("agente externo: input de \(name) não é objeto") }
            calls.append(ToolCall(id: c["id"]?.stringValue ?? "ext\(i)", name: name, input: input))
        }
        let stop: StopReason
        switch msg["stop"]?.stringValue {
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "refusal": stop = .refusal(msg["refusal_category"]?.stringValue)
        default: stop = calls.isEmpty ? .done : .toolUse
        }
        let usage = Usage(inputTokens: Int(msg["usage"]?["input_tokens"]?.numberValue ?? 0),
                          outputTokens: Int(msg["usage"]?["output_tokens"]?.numberValue ?? 0))
        return BrainReply(text: text, toolCalls: calls, stop: stop, raw: nil, usage: usage, model: msg["model"]?.stringValue)
    }
}
